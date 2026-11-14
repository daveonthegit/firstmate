## Absent opt-in: no block and no state
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0

## Opted-in Stop at 310000 tokens requests stow
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0
{"decision":"block","reason":"fm-stow-guard: context is 310000 tokens, near auto-compaction. Run the /stow skill now (full pass), then continue the turn you were in."}

## Repeated Stop in same crossing is silent
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0

## Low-context Stop rearms the crossing
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0

## Next high-context crossing asks again
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0
{"decision":"block","reason":"fm-stow-guard: context is 310000 tokens, near auto-compaction. Run the /stow skill now (full pass), then continue the turn you were in."}

## Foreign-host guard: GROK_AGENT
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0

## Foreign-host guard: GROK_HOOK_EVENT
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0

## Cursor payload stays inert
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0

## A stow older than 24h requests a new full pass
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0
{"decision":"block","reason":"fm-stow-guard: the last /stow is older than 24h. Run the /stow skill now (full pass), then continue the turn you were in."}

## Age request is throttled for one hour
$ {run-worktree}/.live-validation/bin/fm-stow-guard.sh
exit=0

## Task worktree scope refuses a primary Stop block
$ {run-worktree}/bin/fm-stow-guard.sh
exit=0

## Real host adaptive capacity report
$ {run-worktree}/bin/fm-capacity.sh
exit=0
capacity: free_lanes=3 reason=ok lanes=0 target=3 secondmates=0 load1=3.14 cores=10 mem_free_pct=81 disk_free_mb=58207 placed=0 mode=auto budget=3 budget_measured=true
Lanes: 0 running here, 0 on this machine; auto budget 3 (3 open, bound by ceiling).
Per lane: 2 GB, 1 core, 3 GB disk (default until 5 lanes are measured).
Host: load 3.14 on 10 cores, memory free 81%, disk free 58207 MB.

## Real host adaptive capacity JSON
$ {run-worktree}/bin/fm-capacity.sh --json
exit=0
{
  "schema": "fm-lane-capacity.v1",
  "generated_epoch": 1794642120,
  "home": "main",
  "machine": "MacBookPro",
  "lanes": {
    "count": 0,
    "pr_ready": 0,
    "ids": [],
    "placed": 0
  },
  "cap": {
    "target": 3,
    "status": "ok",
    "mode": "auto"
  },
  "projects": [],
  "pressure": {
    "level": "ok",
    "why": [],
    "basis": "probe",
    "beat_age_s": null,
    "avail_gb": 12.8,
    "total_gb": 16,
    "runq_per_core": 0.31,
    "swap_rate_pps_1m": null,
    "mem_stall_pct": null,
    "load1": 3.14,
    "on_battery": null,
    "disks": [
      {
        "label": "home",
        "free_gb": 56.8
      }
    ]
  },
  "uptime_s": 279097,
  "boot_id": "1794363023",
  "boots": [
    1794363023
  ],
  "watcher_beat_age_s": null,
  "reserve": {
    "flag": "not-configured",
    "label": null
  },
  "captain": "not-configured",
  "quota": null,
  "limits": {
    "min_avail_gb": null,
    "min_disk_gb": null,
    "max_load1": null
  },
  "verdict": {
    "admit": true,
    "free_lanes": 3,
    "reasons": []
  },
  "budget": {
    "lanes": 3,
    "open": 3,
    "raw": 3,
    "machine_lanes": 0,
    "by": {
      "memory": 5,
      "cpu": 5,
      "disk": 15,
      "ceiling": 3
    },
    "measured": true,
    "binding": "ceiling",
    "young": 0,
    "damped": false,
    "notes": []
  },
  "footprint": {
    "mem_gb": 2,
    "cpu_cores": 1,
    "disk_gb": 3,
    "source": "default",
    "samples": 0
  },
  "vitals": {
    "load5": 3.44,
    "psi": {
      "cpu_some10": null,
      "mem_some10": null,
      "mem_some60": null,
      "mem_full10": null,
      "io_full10": null,
      "io_full60": null
    },
    "swapin_total": 111570782,
    "swap_in_pps": null,
    "vm_pressure_level": 1,
    "thermal": "ok",
    "battery_pct": 100,
    "on_ac": true,
    "wsl": false,
    "windows": false,
    "host": null,
    "gpu": [
      {
        "name": "Apple M1 Pro",
        "util_pct": 0,
        "mem_used_gb": null,
        "mem_total_gb": null
      }
    ]
  },
  "gates": [
    {
      "name": "cpu",
      "state": "open",
      "since_epoch": null,
      "clear_count": 0
    },
    {
      "name": "memory-pressure",
      "state": "open",
      "since_epoch": null,
      "clear_count": 0
    },
    {
      "name": "thermal",
      "state": "open",
      "since_epoch": null,
      "clear_count": 0
    },
    {
      "name": "battery",
      "state": "open",
      "since_epoch": null,
      "clear_count": 0
    }
  ],
  "reclaim": []
}

## Real host publishes adaptive budget and status
$ {run-worktree}/bin/fm-capacity.sh --publish
exit=0

## Persisted lane-capacity.json public report (including cap.status)
{
  "schema": "fm-lane-capacity.v1",
  "generated_epoch": 1794642120,
  "home": "main",
  "machine": "MacBookPro",
  "lanes": {
    "count": 0,
    "pr_ready": 0,
    "ids": [],
    "placed": 0
  },
  "cap": {
    "target": 3,
    "status": "ok",
    "mode": "auto"
  },
  "projects": [],
  "pressure": {
    "level": "ok",
    "why": [],
    "basis": "probe",
    "beat_age_s": null,
    "avail_gb": 12.8,
    "total_gb": 16,
    "runq_per_core": 0.31,
    "swap_rate_pps_1m": null,
    "mem_stall_pct": null,
    "load1": 3.14,
    "on_battery": null,
    "disks": [
      {
        "label": "home",
        "free_gb": 56.8
      }
    ]
  },
  "uptime_s": 279097,
  "boot_id": "1794363023",
  "boots": [
    1794363023
  ],
  "watcher_beat_age_s": null,
  "reserve": {
    "flag": "not-configured",
    "label": null
  },
  "captain": "not-configured",
  "quota": null,
  "limits": {
    "min_avail_gb": null,
    "min_disk_gb": null,
    "max_load1": null
  },
  "verdict": {
    "admit": true,
    "free_lanes": 3,
    "reasons": []
  },
  "budget": {
    "lanes": 3,
    "open": 3,
    "raw": 3,
    "machine_lanes": 0,
    "by": {
      "memory": 5,
      "cpu": 5,
      "disk": 15,
      "ceiling": 3
    },
    "measured": true,
    "binding": "ceiling",
    "young": 0,
    "damped": false,
    "notes": []
  },
  "footprint": {
    "mem_gb": 2,
    "cpu_cores": 1,
    "disk_gb": 3,
    "source": "default",
    "samples": 0
  },
  "vitals": {
    "load5": 3.44,
    "psi": {
      "cpu_some10": null,
      "mem_some10": null,
      "mem_some60": null,
      "mem_full10": null,
      "io_full10": null,
      "io_full60": null
    },
    "swapin_total": 111570782,
    "swap_in_pps": null,
    "vm_pressure_level": 1,
    "thermal": "ok",
    "battery_pct": 100,
    "on_ac": true,
    "wsl": false,
    "windows": false,
    "host": null,
    "gpu": [
      {
        "name": "Apple M1 Pro",
        "util_pct": 0,
        "mem_used_gb": null,
        "mem_total_gb": null
      }
    ]
  },
  "gates": [
    {
      "name": "cpu",
      "state": "open",
      "since_epoch": null,
      "clear_count": 0
    },
    {
      "name": "memory-pressure",
      "state": "open",
      "since_epoch": null,
      "clear_count": 0
    },
    {
      "name": "thermal",
      "state": "open",
      "since_epoch": null,
      "clear_count": 0
    },
    {
      "name": "battery",
      "state": "open",
      "since_epoch": null,
      "clear_count": 0
    }
  ],
  "reclaim": []
}

## Real local placement uses measured adaptive report
$ {run-worktree}/bin/fm-placement.sh disposable --local-dir {run-worktree}/.live-validation
exit=0
placement: this machine admits - 3 of 3 lanes open (0 running; load 3.14 on 10 cores, memory 80% free)
placement: chose this machine
order: local
