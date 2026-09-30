# deepseek-harness-dev

`docker.io/louisremi/deepseek-harness-dev`: [runzhliu/deepseek-harness](https://github.com/runzhliu/deepseek-harness-docker)
(DeepSeek Harness Web UI, community container) plus two patches and a developer
toolbox. It rebuilds itself whenever upstream or any bundled tool releases.

## What's added on top of upstream

**Patches**

| Patch | Why |
| --- | --- |
| **bubblewrap** (not setuid) | dsh's sandbox tries `bwrap`, then Landlock. Upstream ships no bwrap, and kernels without Landlock (e.g. Unraid) leave no runner. Every shell tool call then needs one-off approval, forever. See runzhliu/deepseek-harness-docker#35. |
| **SameSite=Lax** session cookie | `Strict` blocks the intent-initiated navigation an installed Android PWA uses to log in. |

Both are applied with build-time guards, so an upstream change fails the build
instead of silently shipping an unpatched image.

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

**Host requirement:** on Ubuntu 23.10+ hosts (and derivatives), AppArmor
blocks unprivileged user namespaces by default, and bwrap fails with
`Failed to make / slave: Permission denied`. Check it with
`sysctl kernel.apparmor_restrict_unprivileged_userns`; if it prints `1`, set it
to `0` (`/etc/sysctl.d/60-userns.conf`), as CI does. Unraid, Debian, Fedora
and most other hosts don't have this restriction.

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

## Repository setup (one time)

1. Docker Hub: secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (access token
   with read/write). The public repository `louisremi/deepseek-harness-dev` is
   created by the first publish.
2. Renovate runs as a private GitHub App of your own (Settings → Developer
   settings → GitHub Apps → New):
   - no webhook, no callback URL, *Only on this account*;
   - repository permissions: Contents, Pull requests, Issues, Workflows,
     Commit statuses = read & write; Checks = read-only; Metadata = read-only
     (mandatory);
   - install it on this repository only; generate a private key.

   Then set the variable `RENOVATE_APP_CLIENT_ID` (the app's Client ID), the
   secret `RENOVATE_APP_PRIVATE_KEY` (the `.pem` content), and the variable
   `RENOVATE_PR_AUTHOR` = `<app-slug>[bot]` so `review-gate` also checks who
   opened a PR. [renovate.yml](.github/workflows/renovate.yml) mints a
   one-hour token from them on each run.
3. Settings: enable *Allow auto-merge*. Add branch protection on `main` requiring
   the status checks `review-gate / gate`, `validate`, `build (amd64)` and
   `build (arm64)`, **including for administrators** (the agent's token is
   yours; without this it could push to `main` or merge past the checks).
4. Environments (Settings → Environments): create **`agent-review`** with
   *Required reviewers* = you, and leave *Prevent self-review* **off** (the
   agent's pushes are made with your PAT, so they count as yours). The
   `no-review` environment is created automatically on first use; give it no
   rules.
5. The issue agent (repair + triage) is [maintainer-agent](https://github.com/louisremi/maintainer-agent):
   add this repository to its host config; its behaviour here is set in
   [.github/maintainer-agent.yml](.github/maintainer-agent.yml).

The same settings via `gh`:

```bash
gh repo edit louisremi/deepseek-harness-docker-dev --enable-auto-merge --delete-branch-on-merge
gh secret set DOCKERHUB_USERNAME; gh secret set DOCKERHUB_TOKEN
gh variable set RENOVATE_APP_CLIENT_ID; gh variable set RENOVATE_PR_AUTHOR   # <app-slug>[bot]
gh secret set RENOVATE_APP_PRIVATE_KEY < ~/Downloads/<app-slug>.*.private-key.pem
gh api -X PUT repos/louisremi/deepseek-harness-docker-dev/branches/main/protection --input - <<'EOF'
{"required_status_checks":{"strict":false,"contexts":["review-gate / gate","validate","build (amd64)","build (arm64)"]},
 "enforce_admins":true,"required_pull_request_reviews":null,"restrictions":null}
EOF
me="$(gh api user --jq .id)"
gh api -X PUT repos/louisremi/deepseek-harness-docker-dev/environments/agent-review --input - <<EOF
{"reviewers":[{"type":"User","id":${me}}],"prevent_self_review":false}
EOF
gh api -X PUT repos/louisremi/deepseek-harness-docker-dev/environments/no-review
```

With `enforce_admins` on, your own direct pushes to `main` are refused too.
Work through PRs; only pure Renovate PRs pass `review-gate` on their own, so
approve your own PRs with one click on *Review deployments*.

## Development

See [AGENTS.md](AGENTS.md). In short: `scripts/static-check.sh --online`, then
`docker buildx build --load -t dsh-dev:local . && scripts/smoke.sh dsh-dev:local`.
