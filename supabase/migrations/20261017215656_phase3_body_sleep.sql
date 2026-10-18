-- Additive V3 data; v1 clients keep seeing only the four workout aggregate kinds.
alter table public.tracker_entities drop constraint tracker_entities_kind_check;
alter table public.tracker_entities add constraint tracker_entities_kind_check
  check (kind in ('program','exercise','workout','session','bodyProfile','bodyRecord','sleep'));
create unique index tracker_sleep_night on public.tracker_entities(user_id,(payload->>'wakeDate'))
  where kind='sleep' and not is_deleted;

-- Validate health aggregates before allocating a revision. No names or values
-- from these documents are emitted to diagnostic logs.
create function tracker_private.validate_progress(k text, entity uuid, body jsonb, deleted boolean)
returns void language plpgsql security invoker set search_path = '' as $$
declare v jsonb; metric text; unit_name text; amount numeric;
begin
  if k='bodyProfile' then
    if deleted or entity <> '00000000-0000-0000-0000-000000000003'::uuid then raise exception 'invalid_profile'; end if;
    if nullif(body->'heightCm','null'::jsonb) is not null then
      if jsonb_typeof(body->'heightCm') <> 'string' or (body->>'heightCm') !~ '^(0|[1-9][0-9]{0,11})(\.[0-9]{0,5}[1-9])?$'
        or (body->>'heightCm')::numeric <= 0 then raise exception 'invalid_height'; end if;
    end if;
    if nullif(body->'birthDate','null'::jsonb) is not null then
      if jsonb_typeof(body->'birthDate') <> 'string' or (body->>'birthDate') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        or to_char((body->>'birthDate')::date,'YYYY-MM-DD') <> body->>'birthDate' then raise exception 'invalid_birth_date'; end if;
    end if;
  elsif not deleted and k='bodyRecord' then
    if body->>'source' is distinct from 'manual' or jsonb_typeof(body->'measuredAt') is distinct from 'number'
      or not exists(select 1 from pg_catalog.pg_timezone_names where name=body->>'timezoneID')
      or jsonb_typeof(body->'values') is distinct from 'array' then raise exception 'invalid_body_record'; end if;
    if jsonb_array_length(body->'values') not between 1 and 16 then raise exception 'invalid_body_values'; end if;
    if (select count(distinct value->>'kind') from jsonb_array_elements(body->'values')) <> jsonb_array_length(body->'values')
      or (select count(distinct value->>'id') from jsonb_array_elements(body->'values')) <> jsonb_array_length(body->'values') then raise exception 'duplicate_body_value'; end if;
    if nullif(body->'method','null'::jsonb) is not null and body->>'method' not in ('bioimpedance','dexa','skinfold','other','unspecified') then raise exception 'invalid_method'; end if;
    for v in select value from jsonb_array_elements(body->'values') loop
      metric := v->>'kind';
      if metric not in ('weight','bodyFatPercent','fatMass','skeletalMuscleMass','muscleMass','musclePercent','leanMass','waist','abdomen','chest','hip','arm','forearm','thigh','calf','neck') or metric is null
        or (v->>'id')::uuid is null or coalesce(v->>'position','') !~ '^[0-9]+$' then raise exception 'invalid_metric'; end if;
      unit_name := case when metric in ('bodyFatPercent','musclePercent') then '%'
        when metric in ('waist','abdomen','chest','hip','arm','forearm','thigh','calf','neck') then 'cm' else 'kg' end;
      if v->>'unit' is distinct from unit_name or jsonb_typeof(v->'value') is distinct from 'string'
        or coalesce(v->>'value','') !~ '^(0|[1-9][0-9]{0,11})(\.[0-9]{0,5}[1-9])?$' then raise exception 'invalid_metric_value'; end if;
      amount := (v->>'value')::numeric;
      if (unit_name='%' and amount>100) or ((unit_name='cm' or metric='weight') and amount<=0) then raise exception 'invalid_metric_value'; end if;
      if metric in ('bodyFatPercent','fatMass','skeletalMuscleMass','muscleMass','musclePercent','leanMass')
        and nullif(body->'method','null'::jsonb) is null then raise exception 'composition_method_required'; end if;
    end loop;
  elsif not deleted and k='sleep' then
    if body->>'source' is distinct from 'manual' or jsonb_typeof(body->'startedAt') is distinct from 'number'
      or jsonb_typeof(body->'endedAt') is distinct from 'number' or (body->>'endedAt')::numeric <= (body->>'startedAt')::numeric
      or not exists(select 1 from pg_catalog.pg_timezone_names where name=body->>'startTimezoneID')
      or not exists(select 1 from pg_catalog.pg_timezone_names where name=body->>'endTimezoneID') then raise exception 'invalid_sleep'; end if;
    if body->>'wakeDate' is distinct from to_char(to_timestamp((body->>'endedAt')::double precision/1000) at time zone (body->>'endTimezoneID'),'YYYY-MM-DD') then raise exception 'invalid_wake_date'; end if;
    if nullif(body->'awakenings','null'::jsonb) is not null and (jsonb_typeof(body->'awakenings')<>'number'
      or coalesce(body->>'awakenings','') !~ '^[0-9]+$' or (body->>'awakenings')::numeric > 9223372036854775807) then raise exception 'invalid_awakenings'; end if;
    if nullif(body->'quality','null'::jsonb) is not null and body->>'quality' not in ('poor','fair','good','excellent') then raise exception 'invalid_quality'; end if;
  end if;
  if not deleted and (jsonb_typeof(body->'createdAt') is distinct from 'number' or jsonb_typeof(body->'updatedAt') is distinct from 'number'
    or jsonb_typeof(body->'notes') is distinct from 'string') then raise exception 'invalid_progress_metadata'; end if;
end $$;
revoke all on function tracker_private.validate_progress(text,uuid,jsonb,boolean) from public,anon,authenticated;

create function tracker_private.tracker_apply_mutation_v2(p_mutation jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid(); m uuid; k text; entity uuid; base bigint; body jsonb; deleted boolean;
  existing public.tracker_entities%rowtype; receipt tracker_private.receipts%rowtype;
  response jsonb; competing public.tracker_entities%rowtype; r bigint; related record; item jsonb; one_set jsonb; segment jsonb; target uuid;
begin
  if u is null then raise exception 'authentication_required' using errcode = '42501'; end if;
  if (p_mutation->>'protocolVersion')::int = 1 then return tracker_private.tracker_apply_mutation(p_mutation); end if;
  if (p_mutation->>'protocolVersion')::int is distinct from 2 then raise exception 'unsupported_protocol'; end if;
  m := (p_mutation->>'mutationID')::uuid; k := p_mutation->>'kind'; entity := (p_mutation->>'entityID')::uuid;
  base := (p_mutation->>'baseRevision')::bigint; deleted := (p_mutation->>'deleted')::boolean;
  body := nullif(p_mutation->'payload', 'null'::jsonb);
  if m is null or entity is null or base is null or base < 0 or deleted is null or k not in ('program','exercise','workout','session','bodyProfile','bodyRecord','sleep') then
    raise exception 'invalid_mutation';
  end if;
  if octet_length(p_mutation::text) > 1048576 then raise exception 'snapshot_too_large'; end if;
  if not deleted and (jsonb_typeof(body) is distinct from 'object' or
      (body->>'id')::uuid is distinct from entity or (k in ('program','exercise','workout','session') and nullif(trim(body->>'name'),'') is null)) then raise exception 'invalid_payload'; end if;
  if deleted and body is not null then raise exception 'invalid_deleted_payload'; end if;
  if k in ('bodyProfile','bodyRecord','sleep') then perform tracker_private.validate_progress(k,entity,body,deleted); end if;

  insert into tracker_private.counters(user_id) values (u) on conflict do nothing;
  -- Holding this row lock until COMMIT serializes a user's revision allocation
  -- and prevents a pull cursor from overtaking a still-uncommitted mutation.
  perform 1 from tracker_private.counters where user_id = u for update;
  select * into receipt from tracker_private.receipts where user_id = u and mutation_id = m;
  if found then
    if receipt.request <> p_mutation then raise exception 'mutation_id_reused'; end if;
    return receipt.response;
  end if;
  select * into existing from public.tracker_entities where user_id = u and kind = k and id = entity;
  if coalesce(existing.revision, 0) <> base or (coalesce(existing.is_deleted, false) and not deleted) then
    response := jsonb_build_object('status','conflict','revision',coalesce(existing.revision,0),
      'payload',existing.payload,'deleted',coalesce(existing.is_deleted,true));
  elsif not deleted and k='sleep' and exists (
      select 1 from public.tracker_entities e where e.user_id=u and e.kind='sleep' and not e.is_deleted
        and e.id<>entity and e.payload->>'wakeDate'=body->>'wakeDate') then
    select * into competing from public.tracker_entities e where e.user_id=u and e.kind='sleep' and not e.is_deleted
      and e.id<>entity and e.payload->>'wakeDate'=body->>'wakeDate';
    response := jsonb_build_object('status','duplicateNight','revision',coalesce(existing.revision,0),
      'payload',existing.payload,'deleted',coalesce(existing.is_deleted,true),
      'competingEntityID',competing.id,'competingRevision',competing.revision,'competingPayload',competing.payload);
  elsif deleted and k = 'exercise' and exists (
      select 1 from public.tracker_links l join public.tracker_entities e
        on e.user_id=l.user_id and e.kind=l.source_kind and e.id=l.source_id
      where l.user_id=u and l.target_kind='exercise' and l.target_id=entity and not e.is_deleted) then
    response := jsonb_build_object('status','conflict','revision',existing.revision,'payload',existing.payload,'deleted',false);
  else
    if not deleted and k = 'session' and existing.payload is not null and
      (body->'prescription' is distinct from existing.payload->'prescription' or
       body->'startedAt' is distinct from existing.payload->'startedAt') then
      raise exception 'prescription_is_immutable';
    end if;
    if not deleted and k = 'workout' then
      if jsonb_typeof(body->'items') is distinct from 'array' then raise exception 'invalid_workout'; end if;
      target := (body->>'programID')::uuid;
      if target is not null and not exists (select 1 from public.tracker_entities where user_id=u and kind='program' and id=target and not is_deleted) then
        body := body - 'programID'; -- A deleted program keeps workouts unassigned.
      end if;
      for item in select value from jsonb_array_elements(body->'items') loop
        if not exists (select 1 from public.tracker_entities where user_id=u and kind='exercise' and id=(item->>'exerciseID')::uuid and not is_deleted) then
          raise exception 'exercise_missing: synchronize and resolve the exercise before this workout';
        end if;
      end loop;
    end if;
    r := tracker_private.put(u,k,entity,body,deleted);
    delete from public.tracker_links where user_id=u and source_kind=k and source_id=entity;
    delete from tracker_private.child_ids where user_id=u and root_kind=k and root_id=entity;
    if not deleted and k='bodyRecord' then
      for item in select value from jsonb_array_elements(body->'values') loop
        insert into tracker_private.child_ids values (u,'body_value',(item->>'id')::uuid,k,entity);
      end loop;
    elsif not deleted and k='workout' then
      target := (body->>'programID')::uuid;
      if target is not null then insert into public.tracker_links values (u,k,entity,'program',target); end if;
      for item in select value from jsonb_array_elements(body->'items') loop
        insert into public.tracker_links values (u,k,entity,'exercise',(item->>'exerciseID')::uuid) on conflict do nothing;
        insert into tracker_private.child_ids values (u,'item',(item->>'id')::uuid,k,entity);
        for one_set in select value from jsonb_array_elements(item->'sets') loop
          insert into tracker_private.child_ids values (u,'planned_set',(one_set->>'id')::uuid,k,entity);
        end loop;
      end loop;
    elsif not deleted and k='session' then
      for item in select value from jsonb_array_elements(body->'exercises') loop
        insert into tracker_private.child_ids values (u,'exercise_log',(item->>'id')::uuid,k,entity);
        for one_set in select value from jsonb_array_elements(item->'sets') loop
          insert into tracker_private.child_ids values (u,'set_log',(one_set->>'id')::uuid,k,entity);
          for segment in select value from jsonb_array_elements(one_set->'segments') loop
            insert into tracker_private.child_ids values (u,'segment',(segment->>'id')::uuid,k,entity);
          end loop;
        end loop;
      end loop;
    end if;
    if deleted and k='program' then
      for related in select e.id,e.payload from public.tracker_entities e
        join public.tracker_links l on l.user_id=e.user_id and l.source_kind=e.kind and l.source_id=e.id
        where e.user_id=u and l.target_kind='program' and l.target_id=entity and not e.is_deleted loop
        perform tracker_private.put(u,'workout',related.id,related.payload - 'programID',false);
      end loop;
      delete from public.tracker_links where user_id=u and target_kind='program' and target_id=entity;
    end if;
    response := jsonb_build_object('status','applied','revision',r,'payload',body,'deleted',deleted);
  end if;
  insert into tracker_private.receipts values (u,m,p_mutation,response);
  return response;
end $$;

create or replace function tracker_private.tracker_pull_changes(p_after bigint default 0, p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); result jsonb;
begin
  if u is null then raise exception 'authentication_required' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x.value order by x.revision),'[]'::jsonb) into result from (
    select c.revision, jsonb_build_object('revision',c.revision,'kind',c.kind,'entityID',c.entity_id,
      'payload',c.payload,'deleted',c.is_deleted) value
    from tracker_private.changes c where c.user_id=u and c.kind in ('program','exercise','workout','session') and c.revision > greatest(0,p_after)
    order by c.revision limit greatest(1,least(p_limit,200))
  ) x;
  return result;
end $$;

create function tracker_private.tracker_pull_changes_v2(p_after bigint default 0, p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); result jsonb;
begin
  if u is null then raise exception 'authentication_required' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x.value order by x.revision),'[]'::jsonb) into result from (
    select c.revision, jsonb_build_object('revision',c.revision,'kind',c.kind,'entityID',c.entity_id,
      'payload',c.payload,'deleted',c.is_deleted) value
    from tracker_private.changes c where c.user_id=u and c.revision > greatest(0,p_after)
    order by c.revision limit greatest(1,least(p_limit,200))
  ) x;
  return result;
end $$;

revoke all on function tracker_private.tracker_apply_mutation_v2(jsonb) from public,anon;
revoke all on function tracker_private.tracker_pull_changes_v2(bigint,integer) from public,anon;
grant execute on function tracker_private.tracker_apply_mutation_v2(jsonb) to authenticated;
grant execute on function tracker_private.tracker_pull_changes_v2(bigint,integer) to authenticated;
create function public.tracker_apply_mutation_v2(p_mutation jsonb)
returns jsonb language sql security invoker set search_path = '' as $$
  select tracker_private.tracker_apply_mutation_v2(p_mutation);
$$;
create function public.tracker_pull_changes_v2(p_after bigint default 0,p_limit integer default 100)
returns jsonb language sql security invoker set search_path = '' as $$
  select tracker_private.tracker_pull_changes_v2(p_after,p_limit);
$$;
revoke all on function public.tracker_apply_mutation_v2(jsonb) from public,anon;
revoke all on function public.tracker_pull_changes_v2(bigint,integer) from public,anon;
grant execute on function public.tracker_apply_mutation_v2(jsonb) to authenticated;
grant execute on function public.tracker_pull_changes_v2(bigint,integer) to authenticated;
