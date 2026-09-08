-- CHANGE #239 — the Claude Code device list is now ONE session per worker slot,
-- and the build runs inside it. The old copy described #237's companion model
-- ("each worker slot is listed by command id" — true, but it opened blank),
-- so the hint never told Om the one thing that is now true: tapping a slot
-- shows that build happening live.
-- Copy only. Idempotent: an UPDATE of ui_copy, never a deploy.
insert into ui_copy(key, value) values
  ('dev_queue.ctl_phone_hint_on',
   '"Open Claude Code on your phone — one session per worker slot, named with the command it is building. Tap one to watch that build live."'::jsonb),
  ('dev_queue.ctl_phone_hint_off',
   '"No worker slot has a Remote Control session yet. Each slot opens one when it starts and keeps it for every command it builds."'::jsonb)
on conflict (key) do update set value = excluded.value;
