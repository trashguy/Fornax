# Phase 3005 — Rolling Updates

**Requires: `-Dviceroy=true` at build time.**

## Status: Planned

## Goal

Zero-downtime deployments. When a service manifest changes (new image, new config),
roll out the update incrementally — bring up new instances, verify health, tear down
old ones. No traffic interruption.

## Design

### Update Strategy

```
# In manifest:
update rolling               # default — incremental replacement
update replace               # stop all, start all (for stateful services)
update_batch 1               # how many instances to replace at a time
update_pause 10              # seconds to wait between batches
```

### Rolling Update Sequence

For a service `web` with 3 replicas, updating from v1 to v2:

```
1. Start instance 3 (v2) on available node
2. Wait for instance 3 health check to pass
3. Stop instance 0 (v1)
4. Wait update_pause seconds
5. Start instance 4 (v2)
6. Wait for health check
7. Stop instance 1 (v1)
8. Wait update_pause seconds
9. Start instance 5 (v2)
10. Wait for health check
11. Stop instance 2 (v1)
12. Renumber instances 3,4,5 → 0,1,2
```

At every step, at least 3 healthy instances are running (surge by `update_batch`).

### Rollback

If a new instance fails health checks during rollout:

1. Stop the failed new instance
2. Abort remaining rollout
3. Keep existing old instances running
4. Write failure to `/deploy/active/{service}/events`
5. Mark deployment as "failed" — manual intervention required

```
deploy rollback web           # explicitly revert to previous manifest
```

The deployment server keeps one previous manifest version per service.

### Update Namespace

```
/deploy/active/web/
├── version                   # current deployed version hash
├── previous_version          # previous version (for rollback)
├── update_status             # "none" / "rolling" / "paused" / "failed"
├── update_progress           # "2/3" (instances updated so far)
└── events                    # "12:34:05 rolling update started v1→v2"
```

### cmd/deploy Integration

```
deploy apply web              # triggers rolling update if manifest changed
deploy status web             # shows update progress if in-flight
deploy pause web              # pause a rolling update mid-flight
deploy resume web             # resume paused update
deploy rollback web           # revert to previous version
```

## Dependencies

- Phase 3003: Service manifests + deployment server
- Phase 3004: Health checks (required to verify new instances before cutting over)

## Verify

1. Deploy `web` v1 with 3 replicas — all healthy
2. Update manifest (new image), `deploy apply web`
3. Watch rolling update: new instances come up, old ones go down, one batch at a time
4. Service stays available throughout (no moment with 0 healthy instances)
5. Deploy a bad image — rollout aborts after health check failure, old instances untouched
6. `deploy rollback web` — reverts to previous manifest

## Files

| File | Description |
|------|-------------|
| `srv/deploy/update.zig` | Rolling update logic (part of deployment server) |
