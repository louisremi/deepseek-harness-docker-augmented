# Playbook: tool / library bump failed

## Checksums (release binaries: gh, yq, fzf, atuin)

Symptoms: `sha256sum: WARNING: 1 computed checksum did NOT match`, a 404 in a
`fetch`, or `static-check` "checksum drift".

```bash
python3 scripts/refresh-checksums.py --tool <depName>   # cli/cli, mikefarah/yq, junegunn/fzf, atuinsh/atuin
```

- If it aborts with *downloaded != published*: **stop**. That is a potential
  supply-chain problem, not something to paper over. Report it.
- If the asset URL 404s, upstream renamed its assets. Update the URL template
  in *both* `scripts/refresh-checksums.py` (the `TOOLS` table) and the
  Dockerfile `RUN` step, then rerun the refresh. Keep arm64 and amd64.
- If only one architecture exists for the new release, pin the previous
  version and say so.

## npm (`tools/npm`)

Regenerate the lockfile after editing `package.json`:

```bash
cd tools/npm
npm install --package-lock-only --ignore-scripts --no-audit --no-fund
npm install-scripts ls        # lists packages with install scripts lacking a decision
```

- New package with install scripts: add it to `allowScripts` in
  `package.json`: `true` only if the CLI needs it to work (native addon, binary
  download of the tool itself), otherwise `false`. Explain in the commit.
- `EBADENGINE` / needs newer Node than the base image (Node 24): pin the last
  version supporting Node 24.
- A CLI renamed its bin: update the bin list in the Dockerfile's `npm ci` step,
  the version checks in `scripts/smoke.sh` and the command list in
  `agents/AGENTS.md`.
- Never add AI CLIs (Claude Code, Gemini, Codex, Cursor, Task Master, …):
  excluded on purpose, and `static-check.sh` rejects them.
- Peer conflicts (`ERESOLVE`): prefer holding back the bumped package.

## dsh plugins (`tools/dsh-plugins/package.json`)

Exact pins, installed at build time by `scripts/install-dsh-plugins.mjs`
through `dsh plugin --profile web add`. No lockfile: do not run npm there.

- `PLUGIN GUARD: … is enabled by default but incompatible with dsh …`: the new
  plugin version narrowed its DSH peer ranges. Hold it back to the last
  compatible version and say so. Never move a plugin from `enabled` to disabled
  to make CI pass: that is a human decision.
- `PLUGIN NOTICE: … ships disabled with an exact-version exemption`: expected
  for a disabled plugin; not a failure.
- The smoke test's "with every bundled plugin enabled" step logs a warning,
  not a failure, for errors from disabled plugins. Mention it in the PR.
- A plugin stops being a dsh bundle (`is not a dsh bundle`), or its install
  needs build scripts (the published tarball should be prebuilt): **stop and
  report**.

## Python (`tools/python/requirements.txt`)

The venv installs **wheels only** for CPython 3.13 on x86_64 and aarch64.
`scripts/static-check.sh --online` resolves both. Failures:

- `No matching distribution`: the new version has no cp313 manylinux wheel for
  one architecture yet. Pin the previous version.
- `ResolutionImpossible`: two pins conflict. Move the bumped package back, or
  bump the other side too if a compatible pair exists.
- New transitive dependency without wheels: same, hold back.

## Debian packages

Unpinned by design (they follow the base image and the weekly rebuild). If a
package disappears from trixie, find its replacement on packages.debian.org
and update the list. If it provides a command listed in `agents/AGENTS.md`,
update that file too (the smoke test checks every listed command).
