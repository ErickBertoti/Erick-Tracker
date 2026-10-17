-- Transactional fixtures: no account, data or session remains after rollback.
begin;
insert into auth.users(id,email,role,aud,created_at,updated_at) values
 ('17eaa000-0000-4000-8000-000000000001','tracker-test-a@example.invalid','authenticated','authenticated',now(),now()),
 ('17eaa000-0000-4000-8000-000000000002','tracker-test-b@example.invalid','authenticated','authenticated',now(),now());
set local role authenticated;
do $$
declare request jsonb; first_reply jsonb; repeated jsonb; conflict jsonb;
begin
  perform set_config('request.jwt.claims','{"sub":"17eaa000-0000-4000-8000-000000000001","role":"authenticated"}',true);
  request := '{"protocolVersion":1,"mutationID":"17eaa000-0000-4000-8000-000000000010","kind":"program","entityID":"17eaa000-0000-4000-8000-000000000020","baseRevision":0,"payload":{"id":"17eaa000-0000-4000-8000-000000000020","name":"Teste","position":0,"createdAt":0,"updatedAt":0},"deleted":false}'::jsonb;
  first_reply := public.tracker_apply_mutation(request);
  repeated := public.tracker_apply_mutation(request);
  if first_reply <> repeated or first_reply->>'status' <> 'applied' or (first_reply->>'revision')::bigint <> 1 then raise exception 'idempotency failed'; end if;
  if jsonb_array_length(public.tracker_pull_changes(0,100)) <> 1 then raise exception 'duplicate change'; end if;
  if (select count(*) from public.tracker_entities) <> 1 then raise exception 'own row inaccessible'; end if;
  request := jsonb_set(request,'{mutationID}','"17eaa000-0000-4000-8000-000000000011"');
  conflict := public.tracker_apply_mutation(request);
  if conflict->>'status' <> 'conflict' then raise exception 'revision conflict undetected'; end if;
  begin
    insert into public.tracker_entities(user_id,kind,id,revision,payload) values
      ('17eaa000-0000-4000-8000-000000000001','program','17eaa000-0000-4000-8000-000000000099',100,'{}');
    raise exception 'direct write incorrectly allowed';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims','{"sub":"17eaa000-0000-4000-8000-000000000002","role":"authenticated"}',true);
  if (select count(*) from public.tracker_entities) <> 0 or jsonb_array_length(public.tracker_pull_changes(0,100)) <> 0 then raise exception 'cross-user leak'; end if;
  if (public.tracker_apply_mutation(request)->>'revision')::bigint <> 1 then raise exception 'user sequence not isolated'; end if;
  perform set_config('request.jwt.claims','{"sub":"17eaa000-0000-4000-8000-000000000001","role":"authenticated"}',true);
  request := jsonb_set(request,'{mutationID}','"17eaa000-0000-4000-8000-000000000012"');
  request := jsonb_set(request,'{baseRevision}','1');
  request := jsonb_set(request,'{payload}','null');
  request := jsonb_set(request,'{deleted}','true');
  if public.tracker_apply_mutation(request)->>'status' <> 'applied' then raise exception 'delete failed'; end if;
  if (public.tracker_pull_changes(1,100)->0->>'deleted')::boolean is distinct from true then raise exception 'tombstone absent'; end if;
  request := jsonb_set(request,'{mutationID}','"17eaa000-0000-4000-8000-000000000013"');
  request := jsonb_set(request,'{baseRevision}','2');
  request := jsonb_set(request,'{deleted}','false');
  request := jsonb_set(request,'{payload}','{"id":"17eaa000-0000-4000-8000-000000000020","name":"Ressuscitado"}');
  if public.tracker_apply_mutation(request)->>'status' <> 'conflict' then raise exception 'silent resurrection'; end if;
end $$;
do $$
declare
  program uuid := '17eaa000-0000-4000-8000-000000000030';
  exercise uuid := '17eaa000-0000-4000-8000-000000000031';
  workout uuid := '17eaa000-0000-4000-8000-000000000032';
  session_id uuid := '17eaa000-0000-4000-8000-000000000033';
  body jsonb; request jsonb; reply jsonb; pr bigint; er bigint; wr bigint; sr bigint;
begin
  perform set_config('request.jwt.claims','{"sub":"17eaa000-0000-4000-8000-000000000001","role":"authenticated"}',true);
  request := jsonb_build_object('protocolVersion',1,'mutationID',gen_random_uuid(),'kind','program',
    'entityID',program,'baseRevision',0,'deleted',false,'payload',jsonb_build_object('id',program,'name','Programa'));
  reply := public.tracker_apply_mutation(request); pr := (reply->>'revision')::bigint;
  request := request || jsonb_build_object('mutationID',gen_random_uuid(),'kind','exercise','entityID',exercise,
    'payload',jsonb_build_object('id',exercise,'name','Exercício'));
  reply := public.tracker_apply_mutation(request); er := (reply->>'revision')::bigint;
  body := jsonb_build_object('id',workout,'name','Treino','programID',program,
    'items',jsonb_build_array(jsonb_build_object('id','17eaa000-0000-4000-8000-000000000040','exerciseID',exercise,
      'sets',jsonb_build_array(jsonb_build_object('id','17eaa000-0000-4000-8000-000000000041','reps','12 + 10','load','15 → 10')))));
  request := request || jsonb_build_object('mutationID',gen_random_uuid(),'kind','workout','entityID',workout,'payload',body);
  reply := public.tracker_apply_mutation(request); wr := (reply->>'revision')::bigint;
  if reply->>'status' <> 'applied' or (select count(*) from public.tracker_links where source_id=workout) <> 2 then
    raise exception 'relationships not recorded';
  end if;
  request := request || jsonb_build_object('mutationID',gen_random_uuid(),'kind','exercise','entityID',exercise,
    'baseRevision',er,'payload',null,'deleted',true);
  if public.tracker_apply_mutation(request)->>'status' <> 'conflict' then raise exception 'referenced exercise deleted'; end if;
  request := request || jsonb_build_object('mutationID',gen_random_uuid(),'kind','program','entityID',program,'baseRevision',pr);
  if public.tracker_apply_mutation(request)->>'status' <> 'applied' then raise exception 'program deletion failed'; end if;
  select payload,revision into body,wr from public.tracker_entities where kind='workout' and id=workout;
  if body ? 'programID' or body->'items'->0->'sets'->0->>'load' <> '15 → 10' then
    raise exception 'program cascade lost or changed template';
  end if;
  perform set_config('request.jwt.claims','{"sub":"17eaa000-0000-4000-8000-000000000002","role":"authenticated"}',true);
  request := request || jsonb_build_object('mutationID',gen_random_uuid(),'kind','workout','entityID',gen_random_uuid(),
    'baseRevision',0,'deleted',false,'payload',body);
  request := jsonb_set(request,'{payload,id}',request->'entityID');
  begin
    perform public.tracker_apply_mutation(request); raise exception 'cross_user_reference_accepted';
  exception when others then
    if sqlerrm not like 'exercise_missing:%' then raise; end if;
  end;
  perform set_config('request.jwt.claims','{"sub":"17eaa000-0000-4000-8000-000000000001","role":"authenticated"}',true);
  request := request || jsonb_build_object('mutationID',gen_random_uuid());
  begin
    perform public.tracker_apply_mutation(request); raise exception 'shared_child_ids_accepted';
  exception when unique_violation then null; end;
  body := jsonb_build_object('id',session_id,'name','Sessão','prescription','e30=','startedAt',100,'exercises',jsonb_build_array());
  request := request || jsonb_build_object('mutationID',gen_random_uuid(),'kind','session','entityID',session_id,'payload',body);
  reply := public.tracker_apply_mutation(request); sr := (reply->>'revision')::bigint;
  request := request || jsonb_build_object('mutationID',gen_random_uuid(),'baseRevision',sr,
    'payload',body || jsonb_build_object('prescription','different'));
  begin
    perform public.tracker_apply_mutation(request); raise exception 'history_changed';
  exception when others then
    if sqlerrm <> 'prescription_is_immutable' then raise; end if;
  end;
end $$;
set local role anon;
do $$ begin
  begin
    perform public.tracker_pull_changes(0,100);
    raise exception 'anonymous access incorrectly allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
