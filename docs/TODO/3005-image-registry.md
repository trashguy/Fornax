# Phase 3005 — Image Registry

**Requires: `-Dviceroy=true` at build time.**

## Status: Planned

## Goal

A cluster-local container image store. Nodes pull images from the registry over 9P
instead of reaching out to Docker Hub or other external registries. Minimal — just
a file server that stores and serves image blobs.

## Design

### Registry as a File Server

`srv/registry` serves a namespace of container images. An image is a directory
containing its layers and metadata.

```
/registry/
├── ctl                       # "push <name>:<tag>", "delete <name>:<tag>"
├── images/
│   ├── web-server/
│   │   ├── latest/
│   │   │   ├── manifest      # layer list + metadata (text)
│   │   │   ├── config        # image config (entry point, env, etc.)
│   │   │   └── layers/
│   │   │       ├── 0         # base layer (tar or Fornax container image)
│   │   │       └── 1         # overlay layer
│   │   └── v2.1/
│   │       └── ...
│   └── hello/
│       └── latest/
│           └── ...
└── stats                     # total images, total size
```

### Image Format

Fornax containers (Phase 14) use OCI-compatible images. The registry stores them
as-is — no re-packaging.

### Push / Pull

**Push** (from build machine or external import):
```
deploy push web-server:latest ./image-dir/
```
Copies image directory contents into `/registry/images/web-server/latest/`.

**Pull** (when scheduler places a container on a node):
1. Scheduler tells target node to run `web-server:latest`
2. Target node mounts the registry: `mount("tcp!registry-node!564", "/tmp/reg", "")`
3. Reads image from `/tmp/reg/images/web-server/latest/`
4. Loads and runs the container

### Image Caching

Nodes cache pulled images locally at `/cache/images/`. On next deploy, if the
image manifest hash matches, skip the pull.

### OCI Import

`cmd/deploy` can import from external OCI registries (Docker Hub, etc.) for
bootstrapping:

```
deploy import docker.io/library/nginx:latest
```

This fetches the image (requires networking, Phase 100+), converts to Fornax
format if needed, and pushes to the local registry.

### Why a Custom Registry (not Docker Registry)

- Docker Registry is HTTP-based — we use 9P
- No JSON API, no token auth dance, no blob upload chunking
- Images are just directories of files — `cp` is a valid push mechanism
- Fits naturally into the namespace model

## Dependencies

- Phase 201: Remote namespaces (nodes pull images over 9P)
- Phase 14: Container primitives (OCI image format, already done)
- Phase 100: TCP (for external OCI import, optional)

## Verify

1. Push an image: `deploy push hello:latest ./hello-image/`
2. `ls /registry/images/hello/latest/` — shows manifest, config, layers
3. Deploy service using that image — node pulls from registry, runs container
4. Push same image to a second node cluster — both nodes can pull
5. Delete image: write to ctl — removed from registry

## Files

| File | Description |
|------|-------------|
| `srv/registry/main.zig` | Registry file server |
| `cmd/deploy/push.zig` | Image push logic (part of deploy CLI) |
| `cmd/deploy/import.zig` | External OCI import (optional) |
