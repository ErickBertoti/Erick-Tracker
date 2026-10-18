-- Fictitious identities and values only. Always rolled back.
begin;
insert into auth.users(id,email,role,aud,created_at,updated_at) values
 ('f3a00000-0000-4000-8000-000000000001','progress-a@example.invalid','authenticated','authenticated',now(),now()),
 ('f3a00000-0000-4000-8000-000000000002','progress-b@example.invalid','authenticated','authenticated',now(),now());
set local role authenticated;
do $$
declare req jsonb; reply jsonb; again jsonb; body jsonb; profile jsonb; night jsonb; second_night jsonb;
  id uuid; child uuid; first_revision bigint; legacy jsonb; page jsonb; last_revision bigint; i integer;
begin
  perform set_config('request.jwt.claims','{"sub":"f3a00000-0000-4000-8000-000000000001","role":"authenticated"}',true);
  req := jsonb_build_object('protocolVersion',1,'mutationID',gen_random_uuid(),'kind','program','entityID',gen_random_uuid(),'baseRevision',0,'deleted',false);
  req := req || jsonb_build_object('payload',jsonb_build_object('id',req->'entityID','name','Compatibility fixture','position',0,'createdAt',0,'updatedAt',0));
  reply := public.tracker_apply_mutation(req);
  if public.tracker_apply_mutation_v2(req) <> reply then raise exception 'legacy receipt changed through v2'; end if;
  begin
    perform public.tracker_apply_mutation_v2(jsonb_set(req,'{protocolVersion}','2'));
    raise exception 'receipt incorrectly changed protocol';
  exception when raise_exception then if sqlerrm <> 'mutation_id_reused' then raise; end if; end;

  profile := '{"id":"00000000-0000-0000-0000-000000000003","heightCm":"178.5","birthDate":"1990-02-28","notes":"fixture","createdAt":0,"updatedAt":0}'::jsonb;
  req := jsonb_build_object('protocolVersion',2,'mutationID',gen_random_uuid(),'kind','bodyProfile','entityID',profile->'id','baseRevision',0,'payload',profile,'deleted',false);
  reply := public.tracker_apply_mutation_v2(req);
  if reply->>'status' <> 'applied' or public.tracker_apply_mutation_v2(req) <> reply then raise exception 'profile replay'; end if;
  first_revision := (reply->>'revision')::bigint;
  req := req || jsonb_build_object('mutationID',gen_random_uuid(),'baseRevision',first_revision,'payload',null,'deleted',true);
  begin perform public.tracker_apply_mutation_v2(req); raise exception 'profile deletion allowed';
  exception when raise_exception then if sqlerrm <> 'invalid_profile' then raise; end if; end;

  id := gen_random_uuid(); child := gen_random_uuid();
  body := jsonb_build_object('id',id,'measuredAt',1792224000000,'timezoneID','America/Sao_Paulo','source','manual',
    'method','bioimpedance','methodNotes','fixture','notes','','createdAt',0,'updatedAt',0,
    'values',jsonb_build_array(jsonb_build_object('id',child,'kind','skeletalMuscleMass','unit','kg','value','31.2','position',0),
      jsonb_build_object('id',gen_random_uuid(),'kind','muscleMass','unit','kg','value','40','position',1),
      jsonb_build_object('id',gen_random_uuid(),'kind','leanMass','unit','kg','value','56','position',2),
      jsonb_build_object('id',gen_random_uuid(),'kind','musclePercent','unit','%','value','50','position',3)));
  req := jsonb_build_object('protocolVersion',2,'mutationID',gen_random_uuid(),'kind','bodyRecord','entityID',id,'baseRevision',0,'payload',body,'deleted',false);
  reply := public.tracker_apply_mutation_v2(req);
  if reply->>'status'<>'applied' or reply->'payload'<>body or public.tracker_apply_mutation_v2(req)<>reply then raise exception 'body altered or duplicated'; end if;
  first_revision := (reply->>'revision')::bigint;
  req := req || jsonb_build_object('mutationID',gen_random_uuid(),'entityID',gen_random_uuid());
  req := jsonb_set(req,'{payload,id}',req->'entityID');
  begin perform public.tracker_apply_mutation_v2(req); raise exception 'shared children allowed';
  exception when unique_violation then null; end;
  req := jsonb_set(req,'{payload}',(req->'payload')-'method');
  begin perform public.tracker_apply_mutation_v2(req); raise exception 'missing method allowed';
  exception when raise_exception then if sqlerrm<>'composition_method_required' then raise; end if; end;
  req := jsonb_set(req,'{payload}',body);
  req := jsonb_set(req,'{entityID}',body->'id');
  req := req || jsonb_build_object('mutationID',gen_random_uuid(),'baseRevision',first_revision);
  req := jsonb_set(req,'{payload,values,3,value}','"101"');
  begin perform public.tracker_apply_mutation_v2(req); raise exception 'invalid percent allowed';
  exception when raise_exception then if sqlerrm<>'invalid_metric_value' then raise; end if; end;
  req := jsonb_set(req,'{payload,values,3,value}','"50"');
  req := jsonb_set(req,'{payload,values,0,unit}','"%"');
  begin perform public.tracker_apply_mutation_v2(req); raise exception 'wrong unit allowed';
  exception when raise_exception then if sqlerrm<>'invalid_metric_value' then raise; end if; end;
  req := req || jsonb_build_object('mutationID',gen_random_uuid(),'payload',null,'deleted',true);
  if public.tracker_apply_mutation_v2(req)->>'status'<>'applied' then raise exception 'body deletion failed'; end if;
  reply := public.tracker_apply_mutation_v2(req);
  req := req || jsonb_build_object('mutationID',gen_random_uuid(),'baseRevision',(reply->>'revision')::bigint,'payload',body,'deleted',false);
  if public.tracker_apply_mutation_v2(req)->>'status'<>'conflict' then raise exception 'body resurrected'; end if;

  night := jsonb_build_object('id',gen_random_uuid(),'startedAt',1792204200000,'endedAt',1792231200000,
    'startTimezoneID','America/Sao_Paulo','endTimezoneID','America/Sao_Paulo','wakeDate','2026-10-17',
    'source','manual','notes','','createdAt',0,'updatedAt',0,'awakenings',0);
  req := jsonb_build_object('protocolVersion',2,'mutationID',gen_random_uuid(),'kind','sleep','entityID',night->'id','baseRevision',0,'payload',night,'deleted',false);
  reply := public.tracker_apply_mutation_v2(req);
  if reply->>'status'<>'applied' or reply->'payload'->'awakenings'<>'0'::jsonb then raise exception 'night zero lost'; end if;
  first_revision := (reply->>'revision')::bigint;
  second_night := jsonb_set(night,'{id}',to_jsonb(gen_random_uuid()));
  req := req || jsonb_build_object('mutationID',gen_random_uuid(),'entityID',second_night->'id','payload',second_night);
  reply := public.tracker_apply_mutation_v2(req);
  if reply->>'status'<>'duplicateNight' or reply->'competingEntityID'<>night->'id' or reply->'competingPayload'<>night
    or (reply->>'revision')::bigint<>0 or public.tracker_apply_mutation_v2(req)<>reply then raise exception 'duplicate night lost'; end if;
  -- Legacy payloads are still isolated from all health kinds, even with gaps.
  for i in 1..205 loop
    id := gen_random_uuid();
    body := jsonb_build_object('id',id,'measuredAt',1792224000000,'timezoneID','GMT','source','manual','methodNotes','',
      'notes','','createdAt',0,'updatedAt',0,'values',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'kind','weight','unit','kg','value','80','position',0)));
    req := jsonb_build_object('protocolVersion',2,'mutationID',gen_random_uuid(),'kind','bodyRecord','entityID',id,'baseRevision',0,'payload',body,'deleted',false);
    perform public.tracker_apply_mutation_v2(req);
  end loop;
  req := jsonb_build_object('protocolVersion',1,'mutationID',gen_random_uuid(),'kind','program','entityID',gen_random_uuid(),'baseRevision',0,'deleted',false);
  req := req || jsonb_build_object('payload',jsonb_build_object('id',req->'entityID','name','After health changes','position',0,'createdAt',0,'updatedAt',0));
  reply := public.tracker_apply_mutation_v2(req);
  legacy := public.tracker_pull_changes(0,100);
  if jsonb_array_length(legacy)<>2 or legacy->1->>'entityID'<>req->>'entityID' then raise exception 'legacy pagination skipped training'; end if;
  page := public.tracker_pull_changes_v2(0,200);
  if jsonb_array_length(page)<>200 then raise exception 'v2 page size'; end if;
  last_revision := (page->199->>'revision')::bigint;
  if jsonb_array_length(public.tracker_pull_changes_v2(last_revision,200))<1 then raise exception 'v2 cursor missed health changes'; end if;
  if has_function_privilege('authenticated','tracker_private.validate_progress(text,uuid,jsonb,boolean)','EXECUTE') then raise exception 'helper exposed'; end if;
  begin
    update public.tracker_entities set payload='{}'::jsonb where kind='sleep';
    raise exception 'direct write allowed';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims','{"sub":"f3a00000-0000-4000-8000-000000000002","role":"authenticated"}',true);
  if jsonb_array_length(public.tracker_pull_changes_v2(0,100))<>0 or exists(select 1 from public.tracker_entities) then raise exception 'health cross-user leak'; end if;
  req := jsonb_build_object('protocolVersion',2,'mutationID',gen_random_uuid(),'kind','sleep','entityID',night->'id','baseRevision',0,'payload',night,'deleted',false);
  if public.tracker_apply_mutation_v2(req)->>'status'<>'applied' then raise exception 'night uniqueness crosses users'; end if;
end $$;
reset role;
set local role anon;
do $$ begin
  begin perform public.tracker_pull_changes_v2(0,100); raise exception 'anonymous v2 pull allowed'; exception when insufficient_privilege then null; end;
  begin perform public.tracker_apply_mutation_v2('{}'); raise exception 'anonymous v2 write allowed'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'phase3_protocol_assertions_passed' as result;
rollback;
