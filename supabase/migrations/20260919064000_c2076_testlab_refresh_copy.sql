-- CMD #2076 — copy for the Test Lab card's refresh door.
-- The card header (Semantics identifier dq_testlab_refresh) re-reads the row via
-- dev_cmd_get; this is only the accessibility label the tap carries. Idempotent:
-- an existing row (Om may have reworded it) is left alone.
insert into public.ui_copy (key, value)
values ('dev_queue.testlab_refresh', to_jsonb('Refresh verdict'::text))
on conflict (key) do nothing;
