# Phase 1001: `fay` — Fornax Package Manager

## Overview

Subcommand-style package manager for Fornax, following Plan 9 ethos. Two components:
- **`fay`** — on-device CLI tool (native Zig, in `cmd/fay/`)
- **`fay-build`** — host-side build tool (cross-compiles packages with Zig)
- **`fornax-ports`** — separate GitHub repo holding package definitions (FAYBUILDs)

### Compiler Strategy

Two-tier on-device compilation:
1. **tcc** — ships in base OS image (cross-compiled by Zig). Tiny (~100KB), self-hosting, immediate C capability.
2. **Zig** — installed via `fay install build-essential`. Pre-built cross-compiled binary. Full Zig + C toolchain.

Package repo model:
- Packages are cross-compiled with Zig on the host by `fay-build` (host tool)
- `fay` on-device downloads pre-built .tar.gz packages, verifies SHA-256, extracts+installs
- Once Zig is installed on-device, `fay install --build <pkg>` can build from source locally

## Architecture

### Package Format

Installed packages are tarballs:
```
package.tar.gz
├── .PKGINFO          # metadata (JSON)
├── .INSTALL          # optional post-install fsh script
└── <files>           # installed relative to /
```

### FAYBUILD Format (JSON)

```json
{
  "pkgname": "lua",
  "pkgver": "5.4.7",
  "pkgrel": 1,
  "epoch": 0,
  "pkgdesc": "Lightweight embeddable scripting language",
  "arch": ["x86_64"],
  "realm": "posix",
  "buildable": true,
  "depends": ["tcc"],
  "makedepends": [],
  "source": ["https://www.lua.org/ftp/lua-5.4.7.tar.gz"],
  "sha256sums": ["9fbf5..."],
  "patches": ["lua-fornax.patch"],
  "build": [
    "cd lua-5.4.7/src",
    "tcc -c -DLUA_USE_POSIX *.c",
    "tcc -o lua *.o"
  ],
  "package": [
    "mkdir -p $pkgdir/bin",
    "cp lua-5.4.7/src/lua $pkgdir/bin/lua"
  ]
}
```

- `realm: "posix"` — needs C compiler (tcc or zig cc)
- `realm: "native"` — needs Zig compiler
- `buildable: true` + `build` commands — can be built on-device
- `buildable: false` or no `build` field — binary-only (e.g., Zig toolchain itself)
- `fay install <pkg>` — downloads pre-built binary (default)
- If no binary available + `buildable: true` — prompt: "No binary available. Build locally? [y/n]"
- If no binary + `buildable: false` — error: "No binary available"
- `fay install --build <pkg>` — skip binary check, build from source directly

### Versioning

Arch-style: `epoch:pkgver-pkgrel`
- `epoch` — overrides version comparison (for upstream version scheme changes)
- `pkgver` — upstream version (e.g., "5.4.7")
- `pkgrel` — package revision (incremented for packaging changes, not upstream)
- Comparison: epoch first, then pkgver (segment-by-segment numeric/alpha), then pkgrel

### `fornax-ports` Repo Structure

Sibling repo at `../fornax-ports/` (separate git repo).

```
fornax-ports/
├── repo.json              # auto-generated index (download URLs + sha256)
├── core/                  # base OS packages
│   └── init/FAYBUILD
├── extra/                 # additional packages
│   └── lua/
│       ├── FAYBUILD
│       └── lua-fornax.patch
└── posix/                 # POSIX realm C packages
    └── less/FAYBUILD
```

### `repo.json` Manifest

Single file downloaded by `fay sync`:
```json
{
  "version": 1,
  "packages": {
    "lua": {
      "ver": "5.4.7-1",
      "desc": "Lightweight scripting language",
      "realm": "posix",
      "depends": ["tcc"],
      "url": "http://10.0.2.2:8000/packages/lua-5.4.7-1-x86_64.tar.gz",
      "sha256": "...",
      "path": "posix/lua"
    }
  }
}
```

### Local Package Database

```
/var/lib/fay/
├── local/              # installed packages
│   ├── lua-5.4.7-1/
│   │   ├── desc        # PKGINFO copy
│   │   └── files       # list of installed file paths
│   └── tcc-0.9.27-1/
│       ├── desc
│       └── files
└── sync/
    └── repo.json       # cached repo index
```

### On-Device Directories

```
/var/cache/fay/         # downloaded source tarballs
/var/tmp/fay/           # build working directory
/etc/fay.conf           # configuration (server URL)
```

## `fay` CLI Commands

```
fay sync                    # download repo.json
fay install <pkg> [pkg...]  # resolve deps, download, install
fay remove <pkg>            # remove package
fay upgrade                 # sync + upgrade all installed
fay search <term>           # search repo descriptions
fay list                    # list installed packages
fay info <pkg>              # show package details
```

## Bootstrap Chain

1. **tcc** cross-compiled by Zig, included in disk image (Phase 1001i)
2. tcc can rebuild itself from source (self-hosting)
3. POSIX realm packages built with on-device tcc or downloaded pre-built
4. `build-essential` package ships Zig binary for on-device use (Phase 1001k)

## HTTPS Strategy

GitHub requires HTTPS. Phased approach:
1. **Development**: local HTTP mirror (`python3 -m http.server` on host, QEMU at `http://10.0.2.2:8000/`)
2. **Bootstrap**: port bearssl (15K lines of C, no deps) as early fay package
3. **Production**: native HTTPS in HTTP client library via bearssl

## Dependencies in Fornax Repo

Libraries extracted/created in `lib/` (Phase 1001a-d, 1001l — COMPLETE):

| Library | Purpose | Status |
|---------|---------|--------|
| `lib/crc32.zig` | CRC32 with lookup table | Done |
| `lib/sha256.zig` | SHA-256 (FIPS 180-4) | Done |
| `lib/deflate.zig` | DEFLATE decompression | Done |
| `lib/tar.zig` | USTAR header parsing/creation | Done |
| `lib/json.zig` | SAX-style JSON tokenizer | Done |
| `lib/http.zig` | HTTP/1.1 client over /net/tcp | Done |

Refactored:
- `cmd/tar/main.zig` — uses `fx.tar`, `fx.deflate`, `fx.crc32`
- `cmd/unzip/main.zig` — uses `fx.deflate`, `fx.crc32`

Shell enhancement:
- `cmd/fsh/main.zig` — `for VAR in items...; do body; done` loop

## Implementation Phases

| Sub-phase | Description | Status |
|-----------|-------------|--------|
| 1001a | Extract tar/deflate into `lib/tar.zig`, `lib/deflate.zig` | **Done** |
| 1001b | JSON parser (`lib/json.zig`) | **Done** |
| 1001c | SHA-256 (`lib/sha256.zig`) | **Done** |
| 1001d | HTTP/1.1 client (`lib/http.zig`) | **Done** |
| 1001e | `fay` core: local install/remove/list (from `.tar.gz` on disk) | — |
| 1001f | `fay sync` + remote repo fetch via HTTP | — |
| 1001g | Dependency resolution + `fay install` with auto-deps | — |
| 1001h | `fay upgrade` + Arch-style version comparison | — |
| 1001i | Cross-compile tcc, include in disk image | — |
| 1001j | `fay-build` host tool (reads FAYBUILD, cross-compiles, packages .tar.gz) | — |
| 1001k | `build-essential` package (ships Zig binary for on-device use) | — |
| 1001l | fsh `for` loop for build scripts | **Done** |

## Depends On

- Phase 1000 (C/POSIX realms) — complete
- Phase SMP (multi-core) — complete
- Phases H-K (kernel threads) — complete
