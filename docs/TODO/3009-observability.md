# Phase 3009 — Observability

**Requires: `-Dviceroy=true` at build time.**

## Status: Planned

## Goal

Structured logs and metrics for deployed services — readable as files, queryable
with standard tools. No Prometheus, no Elasticsearch, no Grafana dependency.
`cat` and `grep` are your monitoring stack.

## Design

### Logs

Every service's stdout/stderr is captured and served as a file. Logs are structured
text — one line per entry, machine-parseable but human-readable.

```
/deploy/active/web/logs/
├── 0                         # instance 0 log stream
├── 1                         # instance 1 log stream
├── 2                         # instance 2 log stream
└── all                       # merged stream (all instances, tagged)
```

Log format:
```
2026-02-14T12:34:05Z web/0 INFO request handled path=/index.html status=200 dur=2ms
2026-02-14T12:34:05Z web/1 WARN slow query table=users dur=450ms
2026-02-14T12:34:06Z web/2 ERROR connection refused addr=10.0.0.5:5432
```

Plain text. Grep-able. No JSON wrapping.

### Metrics

Services export metrics by writing to files in their namespace. `srv/deploy`
aggregates them into a cluster-wide view.

```
/deploy/active/web/metrics/
├── requests                  # "15234" (counter, total requests served)
├── errors                    # "12" (counter, total errors)
├── latency_p50               # "3ms"
├── latency_p99               # "45ms"
├── connections               # "42" (gauge, current open connections)
└── memory                    # "28M" (gauge, current RSS)
```

Cluster-wide aggregation:
```
/deploy/metrics/
├── web/
│   ├── requests              # sum across all instances
│   ├── errors
│   ├── latency_p50           # median of medians (approximate)
│   └── ...
└── api/
    └── ...
```

### How Services Export Metrics

A service writes metric files to its own `/metrics/` directory. The convention
is simple: write a number to a file.

```zig
// In a service:
const f = open("/metrics/requests", O_WRITE);
write(f, "15234");
close(f);
```

`srv/deploy` reads these periodically and aggregates.

### Log Retention

- Default: keep last 1000 lines per instance (configurable in manifest)
- Ring buffer — old entries dropped when limit reached
- No disk persistence (ram-only). For persistent logs, pipe to a log service

```
# In manifest:
log_lines 5000                # keep last 5000 lines (default: 1000)
```

### cmd/deploy Integration

```
deploy logs web               # tail merged log stream
deploy logs web/0             # tail specific instance
deploy logs web --since 5m    # last 5 minutes (requires timestamp parsing)
deploy metrics web            # show current metrics snapshot
deploy top                    # cluster-wide overview (like Unix top)
```

### deploy top

A live view of cluster health:

```
CLUSTER: 3 nodes, 7 services, 15 instances

SERVICE    REPLICAS  HEALTHY  REQ/s  ERR/s  P99     MEM
web        3/3       3/3      542    0.1    12ms    84M
api        2/2       2/2      128    0      8ms     32M
db         1/1       1/1      340    0      3ms     256M
worker     3/3       2/3      --     --     --      45M

NODE       CPU   MEM       CONTAINERS  STATUS
fornax-01  23%   128/256M  5           online
fornax-02  45%   96/128M   6           online
fornax-03  12%   64/128M   4           online
```

Text output, refreshed by re-reading files. No curses, no TUI framework needed —
just clear + print.

## Dependencies

- Phase 3003: Service manifests + deployment server
- Phase 3004: Health checks (health state feeds into top view)
- Phase 23: TTY / console (for interactive `deploy top`)

## Verify

1. Deploy a service — logs start flowing to `/deploy/active/web/logs/0`
2. `deploy logs web` — shows merged log stream in real time
3. Service writes to `/metrics/requests` — visible in `deploy metrics web`
4. `deploy top` — shows cluster overview with all services and nodes
5. Kill an instance — logs show the failure, metrics reflect the drop

## Files

| File | Description |
|------|-------------|
| `srv/deploy/logs.zig` | Log capture + aggregation (part of deployment server) |
| `srv/deploy/metrics.zig` | Metrics collection + aggregation |
| `cmd/deploy/top.zig` | Cluster overview display |
