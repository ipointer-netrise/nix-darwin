# Machine recovery exceptions

Status: adopted by MC-15 on 2026-10-03. Canonical registry for unavoidable exceptions to this machine's declarative management policy.

## How to record an exception

An entry needs user approval before it is accepted. Record its source location, rationale, approval, idempotence guard, safe test, recovery impact, and review trigger. Keep the operational procedure in the owning source; this registry records why the exception remains necessary.

Project-state records the decision and review evidence, with a link here. It does not replace this version-controlled document during machine recovery.

## Active entries

### EX-002: XENEON local development signing identity

- Source: login Keychain certificate `XENEON Local Development Signing`; its private key is intentionally not exported or versioned.
- Rationale: preserve macOS Accessibility authorization when the local companion bundle is rebuilt.
- Approval: Ivan Pointer explicitly approved creation on 2026-10-06.
- Idempotence guard: the companion packaging script selects this named identity and fails clearly if it is absent.
- Safe test: package the companion, inspect its designated requirement, relaunch it, then verify the control socket reports Accessibility as ready.
- Recovery impact: recreate this local certificate and renew the Accessibility grant after a machine replacement; no secret belongs in the repository.
- Review trigger: replace this exception when a managed developer signing identity or distribution process exists, or before certificate expiry.

## Retired entries

### EX-001: Antigravity CLI bootstrap installer

- Status: retired on 2026-10-03 with explicit user approval.
- Replacement: the official `antigravity-cli` Homebrew cask, which provides `agy` in the declared Homebrew path.
- Migration verification: `/opt/homebrew/bin/agy` reported 1.2.14 after activation; the legacy `~/.local/bin/agy` and `/usr/local/bin/agy` paths were removed.
- Recovery impact: first boot installs the cask through nix-darwin. Authentication and runtime state remain owned by Antigravity and the macOS Keychain.
