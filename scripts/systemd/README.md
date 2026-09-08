# Versioned systemd units

CHANGE #636. The box's units have always lived only in `~/mediBO-runner/`, and
the GCP→EC2 move proved what that costs: `medibo-backup` was never installed on
the new box and the `backup-lands` journey went red with zero backups in 26 h
before anyone noticed (#224). A unit that exists only on one machine dies with
that machine.

So a unit that a CHANGE introduces is committed here as well, and installing it
is two commands:

```bash
sudo cp scripts/systemd/<unit> /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now <unit>
```

Present:

- `medibo-safety-net.service` / `.timer` — 21:10 UTC (02:40 IST). Drains ONE
  queued `safety_net` request via `scripts/safety_net_lane.sh`. The cron task
  `c636_safety_net_nightly` only enqueues; `autotest_safety_net_run()` is
  minutes of work and cancels at `cron_dispatch()`'s 15 s dblink budget, taking
  every other scheduled task with it (#1808).
