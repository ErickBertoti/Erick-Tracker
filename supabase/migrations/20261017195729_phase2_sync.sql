-- Erick Tracker sync protocol v1. Snapshots are aggregate documents; links enforce
-- ownership across program/exercise/workout references. No client writes tables.
create schema if not exists tracker_private;
revoke all on schema tracker_private from public, anon, authenticated;

create table public.tracker_entities (
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('program','exercise','workout','session')),
  id uuid not null,
  revision bigint not null check (revision > 0),
  payload jsonb,
  is_deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (user_id, kind, id),
  check ((is_deleted and payload is null) or (not is_deleted and jsonb_typeof(payload) = 'object'))
);
create table public.tracker_links (
  user_id uuid not null,
  source_kind text not null,
  source_id uuid not null,
  target_kind text not null,
  target_id uuid not null,
  primary key (user_id, source_kind, source_id, target_kind, target_id),
  foreign key (user_id, source_kind, source_id) references public.tracker_entities(user_id, kind, id) on delete cascade,
  foreign key (user_id, target_kind, target_id) references public.tracker_entities(user_id, kind, id) on delete cascade
);
create index tracker_links_target on public.tracker_links(user_id, target_kind, target_id);
create table tracker_private.counters (
  user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 0
);
create table tracker_private.changes (
  user_id uuid not null references auth.users(id) on delete cascade,
  revision bigint not null,
  kind text not null,
  entity_id uuid not null,
  payload jsonb,
  is_deleted boolean not null,
  primary key (user_id, revision)
);
create table tracker_private.receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  mutation_id uuid not null,
  request jsonb not null,
  response jsonb not null,
  primary key (user_id, mutation_id)
);
create table tracker_private.child_ids (
  user_id uuid not null,
  child_kind text not null,
  child_id uuid not null,
  root_kind text not null,
  root_id uuid not null,
  primary key (user_id, child_kind, child_id),
  foreign key (user_id, root_kind, root_id) references public.tracker_entities(user_id, kind, id) on delete cascade
);
create index tracker_child_root on tracker_private.child_ids(user_id, root_kind, root_id);

alter table public.tracker_entities enable row level security;
alter table public.tracker_links enable row level security;
alter table tracker_private.counters enable row level security;
alter table tracker_private.changes enable row level security;
alter table tracker_private.receipts enable row level security;
alter table tracker_private.child_ids enable row level security;
create policy own_entities on public.tracker_entities for select to authenticated using ((select auth.uid()) = user_id);
create policy own_links on public.tracker_links for select to authenticated using ((select auth.uid()) = user_id);
revoke all on public.tracker_entities, public.tracker_links from public, anon, authenticated;
grant select on public.tracker_entities, public.tracker_links to authenticated;

create function tracker_private.put(p_user uuid, p_kind text, p_id uuid, p_payload jsonb, p_deleted boolean)
returns bigint language plpgsql security invoker set search_path = '' as $$
declare r bigint;
begin
  update tracker_private.counters set revision = revision + 1 where user_id = p_user returning revision into r;
  insert into public.tracker_entities(user_id, kind, id, revision, payload, is_deleted)
    values (p_user, p_kind, p_id, r, p_payload, p_deleted)
    on conflict (user_id, kind, id) do update set revision = excluded.revision,
      payload = excluded.payload, is_deleted = excluded.is_deleted, updated_at = now();
  insert into tracker_private.changes values (p_user, r, p_kind, p_id, p_payload, p_deleted);
  return r;
end $$;
revoke all on function tracker_private.put(uuid,text,uuid,jsonb,boolean) from public, anon, authenticated;

-- SECURITY DEFINER is deliberate here: table writes are denied to API roles so
-- callers cannot bypass revisions/receipts. Every query uses auth.uid(), a fixed
-- search_path, and fully qualified names; only authenticated can execute.
create function public.tracker_apply_mutation(p_mutation jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid(); m uuid; k text; entity uuid; base bigint; body jsonb; deleted boolean;
  existing public.tracker_entities%rowtype; receipt tracker_private.receipts%rowtype;
  response jsonb; r bigint; related record; item jsonb; one_set jsonb; segment jsonb; target uuid;
begin
  if u is null then raise exception 'authentication_required' using errcode = '42501'; end if;
  if (p_mutation->>'protocolVersion')::int is distinct from 1 then raise exception 'unsupported_protocol'; end if;
  m := (p_mutation->>'mutationID')::uuid; k := p_mutation->>'kind'; entity := (p_mutation->>'entityID')::uuid;
  base := (p_mutation->>'baseRevision')::bigint; deleted := (p_mutation->>'deleted')::boolean;
  body := nullif(p_mutation->'payload', 'null'::jsonb);
  if m is null or entity is null or base is null or base < 0 or deleted is null or k not in ('program','exercise','workout','session') then
    raise exception 'invalid_mutation';
  end if;
  if octet_length(p_mutation::text) > 1048576 then raise exception 'snapshot_too_large'; end if;
  if not deleted and (jsonb_typeof(body) is distinct from 'object' or
      (body->>'id')::uuid is distinct from entity or length(trim(body->>'name')) = 0) then raise exception 'invalid_payload'; end if;
  if deleted and body is not null then raise exception 'invalid_deleted_payload'; end if;

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
    if not deleted and k='workout' then
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
revoke all on function public.tracker_apply_mutation(jsonb) from public, anon;
grant execute on function public.tracker_apply_mutation(jsonb) to authenticated;

create function public.tracker_pull_changes(p_after bigint default 0, p_limit integer default 100)
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
revoke all on function public.tracker_pull_changes(bigint,integer) from public, anon;
grant execute on function public.tracker_pull_changes(bigint,integer) to authenticated;
