# Security Policy

## Scope

Fornax is a research/hobby operating system. It is not intended for production use.
That said, we take correctness seriously and want to know about bugs — especially
ones in the kernel that could compromise process isolation or escalate privilege.

## Reporting

If you find a security-relevant bug, open a regular GitHub issue. For this project,
public disclosure is fine — there are no production deployments to protect.

If you'd prefer to report privately, use GitHub's
[private vulnerability reporting](https://github.com/trashguy/Fornax/security/advisories/new).

## What counts

- Privilege escalation (userspace breaking into kernel)
- Process isolation bypass (one process reading/writing another's memory)
- Namespace escape (accessing files outside your mount table)
- IPC confused deputy (impersonating another process over channels)

## What doesn't

- Denial of service (a hobby OS with no uptime SLA)
- Bugs requiring physical access (QEMU is the deployment target)
