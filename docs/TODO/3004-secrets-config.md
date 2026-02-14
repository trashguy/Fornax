# Phase 3004 — Secrets + Config Management

**Requires: `-Dviceroy=true` at build time.**

## Status: Planned

## Goal

Secure distribution of configuration and secrets to services. Secrets are files in an
encrypted namespace — services read them like any other file. No Vault, no
environment variable hacks, no sidecar injectors.

## Design

### Secrets as Files

A secret is a file. A service reads its database password from `/secret/db_password`.
The secret namespace is per-service — each service only sees secrets assigned to it.

```
# In manifest:
secret db_password
secret api_key
config log_level=debug
config max_conn=100
```

- `secret` — references a named secret stored in the cluster secret store
- `config` — plain key-value config, injected as files (not encrypted)

### Secret Storage

`srv/secrets` is a cluster-wide file server that stores encrypted secrets.

```
/secrets/
├── ctl                       # "set db_password <value>", "delete api_key"
├── store/                    # encrypted storage (not directly readable)
│   ├── db_password           # encrypted blob
│   └── api_key               # encrypted blob
├── grants/                   # which services can read which secrets
│   ├── web                   # "db_password\napi_key\n"
│   └── api                   # "api_key\n"
└── key                       # cluster encryption key (generated at init, never exported)
```

### Secret Injection

When `srv/deploy` starts a service instance, it:

1. Reads the service's secret list from the manifest
2. Checks grants — service must be authorized for each secret
3. Decrypts requested secrets
4. Mounts them into the service's namespace at `/secret/*`

The service process only sees plaintext files at `/secret/`. It never touches
the encryption layer.

### Config Injection

Config values from the manifest are simpler — written as plaintext files to
`/config/*` in the service's namespace:

```
/config/
├── log_level                 # "debug"
└── max_conn                  # "100"
```

### cmd/deploy Integration

```
deploy secret set db_password         # prompts for value, encrypts and stores
deploy secret set api_key --file key  # read from file
deploy secret list                    # list all secrets
deploy secret grant web db_password   # authorize service to read secret
deploy secret revoke web db_password  # revoke access
```

### Encryption

- AES-256-GCM for secret encryption at rest
- Cluster encryption key generated at cluster init, stored on each node
- Key rotation: `write /secrets/ctl "rotate-key"` — re-encrypts all secrets
- Transport security via 9P over TLS (Phase 201 stretch goal)

### Why Not Environment Variables

- Env vars leak into child processes, crash dumps, /proc
- Files have permissions and can be revoked at runtime
- Files fit the Plan 9 model — everything is a file
- Config changes don't require process restart (re-read the file)

## Dependencies

- Phase 3000: Service manifests (secret/config declarations)
- Phase 3001: Health checks (restart services if secret injection fails)
- Phase 201: Remote namespaces (distribute secrets across nodes)

## Verify

1. `deploy secret set db_password` — stores encrypted secret
2. `deploy secret grant web db_password` — authorize web service
3. Deploy web — reads `/secret/db_password` successfully
4. Unauthorized service tries to read — access denied
5. `deploy secret revoke web db_password` — web can no longer read it
6. Key rotation — all secrets re-encrypted, services still read them

## Files

| File | Description |
|------|-------------|
| `srv/secrets/main.zig` | Secrets server (encryption, storage, grants) |
| `srv/secrets/crypto.zig` | AES-256-GCM encryption/decryption |
