-- CHANGE #306 — the last few words the screens needed, and the two payload
-- keys that carry them, so no caption is ever written in Dart.
update public.order_alert_config
   set labels = coalesce(labels,'{}'::jsonb) || $lbl${
  "credit_limit_label": "Credit limit",
  "credit_prepaid_label": "Prepaid only"
}$lbl$::jsonb
 where id = 'singleton';
