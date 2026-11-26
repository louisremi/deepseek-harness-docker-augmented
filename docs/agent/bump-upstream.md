# Playbook: upstream DSH image bump failed

Renovate bumped the three base pins `ARG BASE_DEFAULT`, `ARG BASE_BWRAP` and
`ARG BASE_UNGOOGLED` (tag + digest, one grouped PR) and CI went red.

## 0. Do all three pins name the same upstream release?

`static-check.sh` fails with `BASE_<V> is upstream release …, BASE_DEFAULT is …`
when the PR moved only some variants. Upstream publishes `<X-rN>`,
`<X-rN>-bwrap.<B>` and `<X-rN>-ungoogled.<U>` together, but not always at the
same moment. Check Docker Hub
(`curl -s 'https://hub.docker.com/v2/repositories/runzhliu/deepseek-harness/tags?page_size=20' | jq -r '.results[].name'`):

- The missing variant appeared since: Renovate updates the PR on its next run
  (or bump that pin by hand, tag **and** digest).
- It never appears for this release: **stop and report**. Shipping variants of
  different upstream releases, or dropping a variant, is a human decision.

## 1. Did a patch guard fire?

### `PATCH GUARD: dsh-sandbox-local no longer prefers bwrap on linux`

Upstream changed the sandbox runner chain. Find its new shape (no Docker here,
so read the published npm package that matches the DSH version; the tag
`0.2.1-alpha.2-r1` corresponds to `@deepseek-ai/dsh@0.2.1-alpha.2`):

```bash
v=0.2.1-alpha.2   # DSH version = upstream tag without the -rN[-variant.M] suffix
cd "$(mktemp -d)" && npm pack "@deepseek-ai/dsh-sandbox-local@${v}" >/dev/null && tar -xzf *.tgz
grep -n -A6 'PLATFORM_CHAINS' package/lib/index.js
grep -n -A20 'function bwrapProfileArgs' package/lib/index.js
```

- If `linux` still contains `"bwrap"` but formatted differently, adjust the
  guard regex so it still asserts "bwrap is the first linux rung".
- If `bwrap` was removed or demoted, **do not "fix" the guard**. Stop and
  report: bubblewrap in the base image may no longer achieve anything, which
  is a human decision.
- If the bwrap arguments changed (new flags), make `scripts/smoke.sh` exercise
  the same flags, since its bwrap check mirrors `bwrapProfileArgs`.

### `PATCH GUARD: base image has no bwrap on PATH` / `bwrap is setuid` / `not executable by the runtime user`

Bubblewrap is no longer installed by this repository: it comes from upstream's
`-bwrap.N` image variant (introduced with `0.2.1-alpha.1-r1-bwrap.1`; our
report: runzhliu/deepseek-harness-docker#35). Three distinct
assertions share this step, each with its own message: `bwrap` missing from
`PATH`, `bwrap` setuid, or `bwrap` not executable by the runtime user `node`
(e.g. a root-only mode).

These only run for `VARIANT=bwrap`.

- Check the `BASE_BWRAP` tag really ends in `-bwrap.<M>`.
- If upstream stopped publishing `-bwrap.N` tags (or folded bwrap into the
  plain image), **stop and report**. Dropping the variant, or installing
  bubblewrap ourselves, is a human decision that also touches `renovate.json5`,
  `scripts/tag-scheme.sh`, `ci.yml`, `scripts/static-check.sh` and `AGENTS.md`.

### `PATCH GUARD: VARIANT=… expects CHROMIUM_FLAVOR=…`

A base pin points at the wrong upstream variant (e.g. `BASE_UNGOOGLED` at a
plain tag). Fix the pin; never relax the guard.

### `PATCH GUARD: dsh no longer reads DSH_AGENTS_HOME`

Upstream dsh renamed or dropped the shared user-global instructions root, so
`agents/AGENTS.md` would silently stop reaching the model. Read
`@deepseek-ai/dsh-home-paths` and `@deepseek-ai/dsh-agent-instructions` for the
new mechanism. If there is an equivalent, update the `ENV` and the guard. If there
is none, **stop and report**.

### `PLUGIN GUARD: … is enabled by default but incompatible with dsh …`

The new dsh falls outside the DSH peer ranges of a plugin that ships enabled
(`tools/dsh-plugins/package.json`). Look for a newer plugin release that
supports it (`npm view <plugin> versions peerDependencies`) and bump the pin.
If there is none, **stop and report**: shipping it disabled, or with an
exemption, is a human decision. Disabled plugins get an exemption
automatically (`PLUGIN NOTICE` in the log); that is expected, not a failure.
- Never add `chmod u+s` to make it pass.

### `PATCH GUARD: session cookie string not found in dsh-host-authentication-token`

The browser login cookie (the one `/?token=` mints) is not where the step
looks. It has moved before: up to dsh 0.2.2 it lived in
`dsh-client-connection`, since 0.2.3-alpha.2 in `dsh-host-authentication-token`.
Search the whole dsh tree of the new base, since the owner may be a package
dsh only depends on indirectly (so `npm pack` of the direct dependencies can
miss it):

```bash
img=docker.io/runzhliu/deepseek-harness:<new tag>
docker run --rm --entrypoint sh "$img" -c \
  'grep -rln "SameSite=" /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/*/lib'
```

No Docker here? `npm pack` the candidates (`dsh-host-authentication-token`,
`dsh-client-connection`, `dsh-web-app`) at the DSH version and grep them.

- **Moved, same literal:** point `f=` in the Dockerfile step, the guard
  message, `scripts/smoke.sh` (section 3) and `scripts/write-manifest.sh` at
  the new file. The runtime check in `smoke.sh` (the `Set-Cookie` of
  `/?token=` must say `SameSite=Lax`) proves it is the right cookie.
- **Several matches:** patch only the browser login, the cookie set when
  `/?token=` is exchanged. `dsh-client-remote-connection` (`/api/remote.mux`,
  the Remote connection credential) also sets `SameSite=Strict`; it is not
  opened by a PWA launch and stays Strict on purpose.
- **Built differently** (e.g. a `sameSite: "strict"` object form): update the
  sed *and* the guard to the new literal so the result is Lax. Keep the "fail
  if Strict remains" assertion.
- **Upstream now ships Lax:** the step passes on its own. Nothing to do.
- If the move also changed the API `@louisremi/dsh-oidc-login` calls, the
  configured-OIDC block of `smoke.sh` fails, or the logs show `oidc-login:`
  errors or `did not activate`. The plugin registers anonymous `/auth/*`
  routes and an `AuthenticationProvider` through `connection.authentication`,
  and must never claim a route dsh owns (such as `/`). That plugin ships
  enabled: fix it in its own repo (its CI runs the e2e on the newest dsh),
  release it, then bump the pin here. Never disable it here (a human
  decision).
- A **403** there instead (e.g. `browser GET / gave 403`) is dsh's Host/Origin
  fence, not the plugin: since 0.2.3 it applies to every route. The smoke
  test declares its name with `-- --trusted-host dsh.smoke.test` on
  `start()`; keep it.

## 2. Which upstream tag lines do we follow?

Per pin, Renovate's versioning regexes enforce one line: `BASE_DEFAULT` follows
`<X.Y.Z[-pre.N]>-r<N>`, `BASE_BWRAP` follows `…-r<N>-bwrap.<M>` and
`BASE_UNGOOGLED` follows `…-r<N>-ungoogled.<M>`. Never `-market.*`, never `latest`.

## 3. Other upstream changes

- Base OS changed (not trixie / Python not 3.13): Python wheels may no longer
  match. Update `tools/python/requirements.txt` pins and the cp version in
  `scripts/static-check.sh` together.
- Node major changed: check `engines` of the npm CLIs in the lockfile.
- A package we `apt-get install` is now already present: harmless.
- `dsh --version` mismatch in smoke: `smoke.sh` derives the expected version
  from the tag (strip `-rN[-variant.M]`). If upstream changed its tag scheme, adapt that
  derivation *and* the upstream versioning regexes in `renovate.json5`, and
  explain why in the commit message.
- `CMD … differs from upstream's` in smoke: upstream changed its default
  command. Our `ENTRYPOINT` resets it, so copy upstream's new `CMD` into the
  Dockerfile verbatim.
- A command listed in `agents/AGENTS.md` disappeared from the base: install it
  (apt list in the Dockerfile) or remove it from the file. The file must stay
  true.

Never pin back to the old base as a "fix" without explaining why the new one
cannot work.
