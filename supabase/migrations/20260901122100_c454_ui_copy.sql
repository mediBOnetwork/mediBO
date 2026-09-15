-- CMD #454 — every string this command's screens print, in the backend.
insert into public.ui_copy(key,value) values
 ('delivery.accept_expired_chip', to_jsonb('Not accepted — released'::text)),
 ('delivery.act_reassign',    to_jsonb('Reassign'::text)),
 ('delivery.act_rto_receive', to_jsonb('Check back in'::text)),
 ('delivery.act_redeliver',   to_jsonb('Re-deliver'::text)),
 ('delivery.act_track',       to_jsonb('Route taken'::text)),
 ('delivery.track_title',     to_jsonb('Route taken'::text)),
 ('delivery.track_empty',     to_jsonb('No location fixes were recorded for this trip.'::text)),
 ('delivery.partial_title',   to_jsonb('What is coming back?'::text)),
 ('delivery.partial_hint',    to_jsonb('Enter the quantity returned for each item. Leave 0 for anything the customer kept.'::text)),
 ('delivery.partial_submit',  to_jsonb('Record the return'::text))
on conflict (key) do nothing;
