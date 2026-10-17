-- Keep privileged routines outside the exposed API schema. Public entry points
-- are invokers; private implementations derive the owner solely from auth.uid().
alter function public.tracker_apply_mutation(jsonb) set schema tracker_private;
alter function public.tracker_pull_changes(bigint, integer) set schema tracker_private;
grant usage on schema tracker_private to authenticated;
revoke all on function tracker_private.tracker_apply_mutation(jsonb) from public, anon;
revoke all on function tracker_private.tracker_pull_changes(bigint,integer) from public, anon;
grant execute on function tracker_private.tracker_apply_mutation(jsonb) to authenticated;
grant execute on function tracker_private.tracker_pull_changes(bigint,integer) to authenticated;
create function public.tracker_apply_mutation(p_mutation jsonb)
returns jsonb language sql security invoker set search_path = '' as $$
  select tracker_private.tracker_apply_mutation(p_mutation);
$$;
create function public.tracker_pull_changes(p_after bigint default 0, p_limit integer default 100)
returns jsonb language sql security invoker set search_path = '' as $$
  select tracker_private.tracker_pull_changes(p_after, p_limit);
$$;
revoke all on function public.tracker_apply_mutation(jsonb) from public, anon;
revoke all on function public.tracker_pull_changes(bigint,integer) from public, anon;
grant execute on function public.tracker_apply_mutation(jsonb) to authenticated;
grant execute on function public.tracker_pull_changes(bigint,integer) to authenticated;
create policy no_direct_counter_access on tracker_private.counters for all to authenticated using (false) with check (false);
create policy no_direct_change_access on tracker_private.changes for all to authenticated using (false) with check (false);
create policy no_direct_receipt_access on tracker_private.receipts for all to authenticated using (false) with check (false);
create policy no_direct_child_access on tracker_private.child_ids for all to authenticated using (false) with check (false);
