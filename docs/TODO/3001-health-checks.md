# Phase 3001 — Health Checks + Auto-Recovery

**Requires: `-Dviceroy=true` at build time.**

## Status: Planned

## Goal

Production services need liveness monitoring and automatic recovery. Extends the
kernel's VMS-style fault supervisor (Phase 13) to the orchestration layer — if a
service crashes or becomes unhealthy, the deployment server detects it and restarts
or replaces it.

## Design

### Health Check Mechanism

Health is a file read. If the file exists and returns content, the service is healthy.
If the read fails, times out, or returns empty — unhealthy.

```
# In the service manifest:
health /srv/web/health
health_interval 5
health_timeout 3
health_retries 3
```

- `health` — path to read (relative to service's namespace)
- `health_interval` — seconds between checks (default: 10)
- `health_timeout` — seconds before a check is considered failed (default: 5)
- `health_retries` — consecutive failures before marking unhealthy (default: 3)

### Why File Reads (not HTTP, not TCP)

- Everything in Fornax is a file — health checks use the same primitive
- No HTTP stack needed in the health checker
- Services already export state via their namespace
- A healthy service that serves files... can serve its health file
- TCP liveness is a subset (if the 9P connection works, TCP works)

### Health States

```
healthy     → check passes
unhealthy   → check failed >= health_retries consecutive times
starting    → grace period after launch (no checks yet)
stopped     → intentionally stopped, no checks
```

### Recovery Actions

When a service instance becomes unhealthy:

1. **Local restart** (default): Kill and restart on same node
2. **Reschedule**: If local restart fails 3 times, place on a different node
3. **Alert**: Write event to `/deploy/active/{service}/events`

```
# In manifest:
restart always              # always restart (default)
restart never               # let it stay dead
restart on-failure          # restart only on non-zero exit
max_restarts 5              # give up after 5 restarts in 60s
```

### Integration with srv/deploy

The deployment server (Phase 3000) runs health checks for all active services.
It reads the health path via the service's mounted namespace (local or remote via 9P).

```
check_health(service, instance):
  path = "/deploy/active/{service}/instances/{instance}/ns/{health_path}"
  result = read(path, timeout=health_timeout)
  if result.ok:
    mark_healthy(instance)
  else:
    increment_failure_count(instance)
    if failures >= health_retries:
      recover(service, instance)
```

### Health Namespace

```
/deploy/active/web/
├── health                    # "healthy" / "degraded" / "unhealthy" (aggregate)
├── instances/
│   ├── 0                     # includes health state
│   ├── 1
│   └── 2
└── events                    # "12:34:05 instance 1 unhealthy, restarting"
```

## Dependencies

- Phase 3000: Service manifests + deployment server
- Phase 13: VMS fault supervisor (kernel-level crash recovery, already done)

## Verify

1. Deploy a service with `health /srv/test/health`
2. Service starts, health checks pass — status shows "healthy"
3. Kill the service process — detected within `health_interval` seconds
4. Auto-restarted, returns to "healthy"
5. Make the health file return failure — after `health_retries` failures, restarted
6. Exceed `max_restarts` — service marked "failed", event logged

## Files

| File | Description |
|------|-------------|
| `srv/deploy/health.zig` | Health check loop (part of deployment server) |
