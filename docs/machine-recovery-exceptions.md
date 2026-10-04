# Machine recovery exceptions

Status: adopted by MC-15 on 2026-10-03. Canonical registry for unavoidable exceptions to this machine's declarative management policy.

## How to record an exception

An entry needs user approval before it is accepted. Record its source location, rationale, approval, idempotence guard, safe test, recovery impact, and review trigger. Keep the operational procedure in the owning source; this registry records why the exception remains necessary.

Project-state records the decision and review evidence, with a link here. It does not replace this version-controlled document during machine recovery.

## Entries awaiting confirmation

### EX-CAND-001: Antigravity CLI bootstrap installer

- Source: `flake.nix`, `mkSelfUpdatingHarness` and the Antigravity CLI entry.
- Current behavior: activation runs the vendor installer only when `~/.local/bin/agy` is absent, then maintains a stable `/usr/local/bin/agy` link.
- Why it needs review: it is an existing imperative installer and predates this registry.
- Next action: obtain explicit user confirmation before treating it as an accepted exception or changing its behavior.
