# Playbook: upstream DSH image bump failed

Renovate bumped `ARG DSH_BASE_IMAGE` (tag + digest) and CI went red.

## 1. Did a patch guard fire?

### `PATCH GUARD: dsh-sandbox-local no longer prefers bwrap on linux`

Upstream changed the sandbox runner chain. Find its new shape (no Docker here,
so read the published npm package that matches the DSH version; the tag
`0.1.7-rc.3-r1` corresponds to `@deepseek-ai/dsh@0.1.7-rc.3`):

```bash
v=0.1.7-rc.3   # DSH version = upstream tag without the -rN suffix
cd "$(mktemp -d)" && npm pack "@deepseek-ai/dsh-sandbox-local@${v}" >/dev/null && tar -xzf *.tgz
grep -n -A6 'PLATFORM_CHAINS' package/lib/index.js
grep -n -A20 'function bwrapProfileArgs' package/lib/index.js
```

- If `linux` still contains `"bwrap"` but formatted differently, adjust the
  guard regex so it still asserts "bwrap is the first linux rung".
- If `bwrap` was removed or demoted, **do not "fix" the guard**. Stop and
  report: the bubblewrap patch may no longer achieve anything, which is a
  human decision.
- If the bwrap arguments changed (new flags), make `scripts/smoke.sh` exercise
  the same flags, since its bwrap check mirrors `bwrapProfileArgs`.

### `PATCH GUARD: session cookie string not found in dsh-client-connection`

```bash
cd "$(mktemp -d)" && npm pack "@deepseek-ai/dsh-client-connection@${v}" >/dev/null && tar -xzf *.tgz
grep -n 'SameSite' package/lib/*.js
```

- If the cookie is now built differently (e.g. `sameSite: "strict"` object
  form), update the sed *and* the guard to the new literal so the result is
  Lax. Keep the "fail if Strict remains" assertion.
- If upstream now ships Lax, the step passes on its own. Nothing to do.

## 2. Is bubblewrap now shipped by upstream?

If `command -v bwrap` would succeed in the new base (check the upstream
Dockerfile in `runzhliu/deepseek-harness-docker` at the matching release),
our install becomes a harmless no-op. Keep it, and mention it in the summary
(upstream issue runzhliu/deepseek-harness-docker#35).

## 3. Other upstream changes

- Base OS changed (not trixie / Python not 3.13): Python wheels may no longer
  match. Update `tools/python/requirements.txt` pins and the cp version in
  `scripts/static-check.sh` together.
- Node major changed: check `engines` of the npm CLIs in the lockfile.
- A package we `apt-get install` is now already present: harmless.
- `dsh --version` mismatch in smoke: `smoke.sh` derives the expected version
  from the tag (strip `-rN`). If upstream changed its tag scheme, adapt that
  derivation *and* the upstream versioning regex in `renovate.json5`, and
  explain why in the commit message.

Never pin back to the old base as a "fix" without explaining why the new one
cannot work.
