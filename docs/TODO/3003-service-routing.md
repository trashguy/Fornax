# Phase 3003 — Service Routing

**Requires: `-Dviceroy=true` at build time.**

## Status: Planned

## Goal

Namespace-based service discovery and load balancing. Services find each other by
name, not by IP:port. A routing server distributes requests across healthy replicas.
No service mesh sidecar, no iptables — just 9P namespace mounts.

## Design

### How It Works

When service `api` needs to talk to service `web`:

1. `api` opens `/svc/web/request` — this is a mount point served by `srv/route`
2. `srv/route` picks a healthy `web` instance (round-robin, least-connections, etc.)
3. Routes the 9P request to that instance via its remote namespace mount
4. Response flows back through the same path

The caller doesn't know which instance it hit. Retries and failover are transparent.

### Service Registration

When `srv/deploy` starts a service, it registers it with `srv/route`:

```
write /svc/route/ctl "register web 10.0.0.2:564/srv/web"
write /svc/route/ctl "register web 10.0.0.3:564/srv/web"
write /svc/route/ctl "register web 10.0.0.4:564/srv/web"
```

When an instance goes unhealthy or is stopped, `srv/deploy` deregisters it:

```
write /svc/route/ctl "deregister web 10.0.0.2:564/srv/web"
```

### Routing Namespace

```
/svc/
├── route/
│   ├── ctl                   # register/deregister commands
│   └── policy                # "round-robin" / "least-conn" / "random"
├── web/                      # virtual mount — proxied to a web instance
│   ├── health
│   ├── request
│   └── ...
├── api/                      # virtual mount — proxied to an api instance
│   └── ...
└── db/
    └── ...
```

### Load Balancing Policies

```
round-robin                   # rotate through instances (default)
least-conn                    # pick instance with fewest active connections
random                        # random selection
sticky <key>                  # route same client to same instance
```

Set per-service:
```
write /svc/route/ctl "policy web least-conn"
```

### Why Not DNS-Based Discovery

- DNS adds latency (lookup + cache invalidation delay)
- DNS can't do per-request load balancing
- Fornax already has namespace mounts — use them
- No extra daemon (no CoreDNS, no consul)

### Extracting Port from Manifests

If the manifest declares `port 8080`, that's what the service listens on internally.
`srv/route` connects to the 9P namespace of the instance, not to a raw TCP port.
The service's internal port is only relevant to the service itself.

## Dependencies

- Phase 3000: Service manifests (registration info comes from deploy server)
- Phase 3001: Health checks (only route to healthy instances)
- Phase 201: Remote namespaces (9P connections to service instances)

## Verify

1. Deploy `web` with 3 replicas
2. From another service, `read /svc/web/health` — routed to a healthy instance
3. Kill one instance — subsequent requests go to remaining instances (no errors)
4. Scale up — new instance auto-registered, starts receiving traffic
5. Set `policy web least-conn` — verify requests favor less-loaded instances

## Files

| File | Description |
|------|-------------|
| `srv/route/main.zig` | Routing server (serves /svc/* namespace) |
