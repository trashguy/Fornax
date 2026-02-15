# Phase 3003 — Service Manifests + cmd/deploy

**Requires: `-Dviceroy=true` at build time (implies `-Dcluster=true`).**

## Status: Planned

## Goal

Declarative service definitions and a deploy command. No YAML, no CRDs — plain text
files describing what to run, how many, and where. The deploy tool reads manifests and
talks to the cluster scheduler (Phase 3002) via `/cluster/scheduler/ctl`.

## Design

### Manifest Format

Simple key-value text files. One file per service. Plan 9 spirit — human-readable,
`cat`-able, `grep`-able.

```
# /deploy/manifests/web
name web
image web-server
replicas 3
memory 64M
cpu 1
health /srv/web/health
restart always
port 8080
env DB_ADDR=10.0.0.5
env DB_PORT=5432
```

No nesting, no indentation semantics, no schema versioning. A service manifest is a
flat list of directives. Unknown directives are ignored (forward compat). Comments
start with `#`.

### Why Not YAML/TOML/JSON

- Text files are grep-able, diff-able, cat-able without tooling
- No parser dependencies beyond line splitting
- Matches Plan 9's control file conventions (write text to ctl files)
- Humans can write and read manifests without documentation

### cmd/deploy

```
deploy apply web              # read /deploy/manifests/web, schedule via cluster
deploy status                 # show all deployed services
deploy status web             # show service detail
deploy scale web 5            # update replica count
deploy stop web               # tear down all replicas
deploy logs web               # tail logs (see Phase 3009)
```

`cmd/deploy` is a thin client. It reads manifest files, writes commands to
`/cluster/scheduler/ctl`, and reads state from `/cluster/scheduler/placements/*`.
No daemon, no API server — just file operations.

### Deployment Namespace

```
/deploy/
├── manifests/                # service definitions (text files)
│   ├── web
│   ├── api
│   └── db
├── active/                   # currently deployed services (read-only, from scheduler)
│   ├── web/
│   │   ├── manifest          # copy of deployed manifest
│   │   ├── replicas          # "3" (current count)
│   │   ├── instances/        # per-instance state
│   │   │   ├── 0             # "node=fornax-01 status=running pid=42"
│   │   │   ├── 1             # "node=fornax-02 status=running pid=17"
│   │   │   └── 2             # "node=fornax-03 status=running pid=23"
│   │   └── events            # deployment history (append-only text)
│   └── api/
│       └── ...
└── ctl                       # write: "apply web", "scale web 5", "stop web"
```

### srv/deploy — Deployment Server

A file server that:
1. Serves `/deploy/*` namespace
2. Watches manifest files for changes
3. Translates deploy commands into scheduler operations
4. Tracks deployment state (desired vs actual replicas)
5. Reconciliation loop: if actual != desired, issue scheduler commands

This is the only daemon. `cmd/deploy` is stateless.

## Dependencies

- Phase 3002: Cluster scheduler (container placement)
- Phase 3001: Remote namespaces (9P over TCP, for cross-node operations)
- Phase 20: Initrd or equivalent (to distribute manifest files)

## Verify

1. Write a manifest file to `/deploy/manifests/web`
2. Run `deploy apply web` — service starts on cluster
3. `deploy status web` shows 3 running replicas across nodes
4. Edit manifest, `deploy apply web` again — reconciles to new state
5. `deploy stop web` — all replicas torn down

## Files

| File | Description |
|------|-------------|
| `cmd/deploy/main.zig` | Deploy CLI tool |
| `srv/deploy/main.zig` | Deployment server (serves /deploy/* namespace) |
