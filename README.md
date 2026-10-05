# deepseek-harness-dev

`docker.io/louisremi/deepseek-harness-dev`: [runzhliu/deepseek-harness](https://github.com/runzhliu/deepseek-harness-docker)
(DeepSeek Harness Web UI, community container) plus two patches, a dsh plugin
and a developer toolbox. It rebuilds itself whenever upstream or any bundled
tool releases.

## What's added on top of upstream

**Patches**

| Patch | Why |
| --- | --- |
| **bubblewrap** (not setuid) | dsh's sandbox tries `bwrap`, then Landlock. Upstream ships no bwrap, and kernels without Landlock (e.g. Unraid) leave no runner. Every shell tool call then needs one-off approval, forever. See runzhliu/deepseek-harness-docker#35. |
| **SameSite=Lax** session cookie | `Strict` blocks the intent-initiated navigation an installed Android PWA uses to log in. |

Both are applied with build-time guards, so an upstream change fails the build
instead of silently shipping an unpatched image.

**dsh plugin**

| Plugin | Why |
| --- | --- |
| **[@louisremi/dsh-docker-adapter](https://github.com/louisremi/dsh-docker-adapter)** | The Harness runs somewhere else and you drive it from a browser, so "Show file location" opens a file manager nobody is using. The plugin replaces those buttons with **Download file** buttons, backed by an authenticated `GET /api/download.file`. |

It is baked into the `web` profile with dsh's own `dsh plugin --profile web
add`, so nothing is downloaded at runtime. Docker seeds a **new** `dsh-home`
volume from the image; a volume that already exists keeps the profile it has,
so add it once:
`docker compose exec deepseek-harness dsh plugin --profile web add @louisremi/dsh-docker-adapter`.

**Tools** (HolyClaude *slim* parity, minus its CloudCLI web UI, s6 and SSH/Mosh server)

- apt: fd, bat, tree, tmux, nano, shellcheck, dig, strace, lsof, iproute2, htop,
  psql, redis-cli, sqlite3, mysql/mariadb client, ImageMagick, emoji fonts
  (upstream already has git, curl, wget, jq, ripgrep, zip, rsync, ssh, gcc/make,
  Chromium)
- release binaries, sha256-pinned per arch: **gh**, **yq**, **fzf**, **atuin**, **cursor-agent**
- npm: **Claude Code**, **Gemini CLI**, **Codex**, **Task Master**, TypeScript,
  tsx, Vite, esbuild, ESLint, Prettier, serve, nodemon, concurrently,
  dotenv-cli, Playwright (uses upstream's Chromium)
- Python venv `/opt/devtools/venv`: requests, httpx, bs4, lxml, Pillow, pandas,
  numpy, openpyxl, python-docx, jinja2, pyyaml, rich, click, pytest, playwright,
  apprise, bandit, tree-sitter, desloppify, …

Upstream's `dsh`, `node`, `python3` and `pnpm` keep PATH precedence.

## Run

```bash
DSH_WORKSPACE=/abs/path/to/project docker compose -f compose.example.yaml up -d
docker compose -f compose.example.yaml logs deepseek-harness | grep 'dsh web:'
```

bubblewrap needs `security_opt: [seccomp=unconfined, systempaths=unconfined]`,
which is already in `compose.example.yaml`. Capabilities stay dropped.

**AppArmor hosts** (Ubuntu, some Debian setups): Docker's `docker-default`
profile blocks bwrap's mounts (`bwrap: Failed to make / slave: Permission
denied`), so the example also sets `apparmor=unconfined` (a no-op on hosts
without AppArmor, like Unraid). On Ubuntu 23.10+ also set the host sysctl
`kernel.apparmor_restrict_unprivileged_userns=0`
(`/etc/sysctl.d/60-userns.conf`), as CI does.

**Tags:** `<upstream-tag>-dev.<N>` (e.g. `0.1.7-rc.2-r1-dev.1`) and `latest`.
Images are published for linux/amd64 and linux/arm64.

## How it stays up to date

```
Renovate (every 2h, self-hosted in Actions)
  └─ PR per update: upstream image (tag+digest) · gh/yq/fzf/atuin/cursor (+ sha256 refresh)
                    · npm CLIs · Python libs · Actions      + "Dependency Dashboard" issue
       └─ CI: static checks → build amd64+arm64 → smoke test (hardened runtime, bwrap, Lax cookie, all tools)
            ├─ green → GitHub auto-merge → main CI → publish <upstream>-dev.<N> + latest
            └─ red   → issue [agent-fix] → maintainer-agent (self-hosted) pushes a fix
                                                            → CI green → issue closed → maintainer reviews + merges
Weekly rebuild picks up Debian security updates; it publishes only if the image inventory changed.

New issues ──► same agent, triage mode (sandboxed, offline, no token): investigates and posts one first answer
               (maintainer issues automatically; others after a maintainer adds the `triage` label)
               maintainer adds `agent-fix` ──► agent implements it on maintainer-agent/issue-<n> ──► draft PR for review

Agent-written code never auto-merges: the required `review-gate` check waits for a maintainer.
```

### Why Renovate and not Dependabot

Dependabot opens PRs only, never issues. It can't follow `FROM ${ARG}`
([dependabot-core#4597](https://github.com/dependabot/dependabot-core/issues/4597)),
binaries downloaded from GitHub Releases or Cursor's bucket, or packages
installed inline by a Dockerfile. It also treats `-rc`/`-alpha` tags as
prereleases. Renovate handles all of these with one config, and its Dependency
Dashboard issue gives the issue-based overview.

## Development

See [AGENTS.md](AGENTS.md). In short: `scripts/static-check.sh --online`, then
`docker buildx build --load -t dsh-dev:local . && scripts/smoke.sh dsh-dev:local`.

Setting up this repository or a fork from scratch (secrets, Renovate app,
branch protection): see [SETUP.md](SETUP.md).
