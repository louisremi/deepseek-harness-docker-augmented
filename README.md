# deepseek-harness-docker-augmented

`docker.io/louisremi/deepseek-harness-augmented`: every image of
[runzhliu/deepseek-harness](https://github.com/runzhliu/deepseek-harness-docker)
(the community DeepSeek Harness container) except `-market`, rebuilt with a few
additions and kept as close to upstream as possible. It rebuilds itself
whenever upstream, a bundled tool or a bundled plugin releases.

## Variants and tags

| Variant | Built from upstream | Immutable tag | Moving tag |
| --- | --- | --- | --- |
| **default** | `<X-rN>` | `<X-rN>-augmented.<N>` | `latest` |
| **bwrap** (bubblewrap sandbox, for kernels without Landlock) | `<X-rN>-bwrap.<B>` | `<X-rN>-bwrap.<B>-augmented.<N>` | `bwrap` |
| **ungoogled** (ungoogled-chromium) | `<X-rN>-ungoogled.<U>` | `<X-rN>-ungoogled.<U>-augmented.<N>` | `ungoogled` |

For example, `0.2.1-alpha.2-r1-augmented.2`, `0.2.1-alpha.2-r1-bwrap.1-augmented.2`
and `0.2.1-alpha.2-r1-ungoogled.1-augmented.2` are one publish. N counts
publishes per upstream release and is shared by the three variants. Each
publish has one [GitHub Release](https://github.com/louisremi/deepseek-harness-docker-augmented/releases),
named after the default tag, listing all three images. Images are linux/amd64
and linux/arm64. Upstream's `-market` image is not derived: its plugin market
ships here as a plugin you can switch on (below).

> **Breaking change in `…-augmented.2`:** `latest` used to be the bubblewrap
> build and is now the **default** variant, like upstream's default image. If
> your host has no Landlock (Unraid, some NAS kernels) and you rely on the
> bubblewrap sandbox, switch to `:bwrap` and add
> [compose.bwrap.yaml](compose.bwrap.yaml).
>
> Previously published as `louisremi/deepseek-harness-dev` and
> `louisremi/deepseek-harness-devkit` (`…-dev.N`). Those repositories are
> deprecated and get no new tags.

## What's added on top of upstream

**1. SameSite=Lax session cookie** (all variants). With `Strict`, an installed
Android PWA can't log in, because it launches through an intent-initiated
navigation. The value is compiled into dsh, so a guarded build-time patch
rewrites it: an upstream change fails the build instead of shipping an
unpatched image.

**2. dsh plugins**, pre-installed in the `web` profile:

| Plugin | Default | What it does |
| --- | --- | --- |
| [@louisremi/dsh-always-on](https://github.com/louisremi/dsh-always-on) | **on** | The Harness runs remotely, so "show file location" and "Open in app" have no desktop to reach. This plugin replaces them with **Download file**, **Show files** (sidebar explorer) and an in-browser **Edit** button. |
| [dshmarket](https://github.com/dsh-market/dsh-market) | off | Community plugin market. Seeded with `allowRestart: false`, because the container owns the lifecycle: restart the container instead. |
| [dsh-plugin-subscriptions](https://github.com/V1ki/dsh-plugin-subscriptions) | off | Use ChatGPT (Codex), Claude, Grok, Copilot and Antigravity subscriptions as model providers. |

Turn the "off" plugins on from the sidebar's **Plugins** page. They are
already installed, so this needs no network. A plugin that ships off may
declare DSH peer ranges that exclude the bundled dsh (currently
dsh-plugin-subscriptions). The build then records an exact-version exemption
so that it stays installable. **Enabling it is at your own risk** until its
author widens the range. A plugin that ships on must be compatible, or the
build fails.

Seeding happens at start-up: a Harness home (`/home/node/.dsh`, named volume
or bind mount) **without** a `web` profile gets a copy of the image's profile
and pnpm store. An **existing** profile is never modified. Instead the logs
print the command for every bundled plugin it lacks:

```bash
docker compose exec deepseek-harness dsh plugin --profile web add @louisremi/dsh-always-on@<version>
# replaced by dsh-always-on (same routes): remove it first if you had it
docker compose exec deepseek-harness dsh plugin --profile web remove @louisremi/dsh-docker-adapter
```

If you created your volume with an earlier image and `dsh plugin add` fails with
`ERR_PNPM_UNEXPECTED_STORE`, run upstream's one-time migration
(`dsh-market-repair-store`, see upstream's README). Alternatively, back up
`profiles/web` and let the image re-seed it. Set `DSH_AUGMENTED_SEED=0` to
disable seeding.

**3. Developer tools** from [HolyClaude](https://github.com/CoderLuii/HolyClaude#both-variants-full--slim)'s
"both variants" list, minus its AI CLIs (Claude Code, Gemini, Codex, Cursor,
Task Master) and minus what upstream already ships (git, curl, wget, jq,
ripgrep, zip, rsync, ssh, gcc/make, ImageMagick, Chromium, pnpm):

- apt: fd, bat, tree, tmux, nano, shellcheck, dig, ip/ss, strace, lsof, htop,
  psql, redis-cli, sqlite3, mysql/mysqldump (MariaDB), pkg-config, emoji fonts
- release binaries, sha256-pinned per arch: **gh**, **yq**, **fzf**, **atuin**
- npm: TypeScript, tsx, Vite, esbuild, ESLint, Prettier, serve, nodemon,
  concurrently, dotenv-cli, Playwright (uses upstream's Chromium)
- Python venv `/opt/devtools/venv`, which is the `python`/`pip` on PATH:
  requests, httpx, bs4, lxml, Pillow, pandas, numpy, openpyxl, python-docx,
  jinja2, markdown, pyyaml, rich, click, tqdm, pytest, flake8, bandit,
  tree-sitter, desloppify, playwright, apprise, …

Upstream's `dsh`, `node`, `python3` and `pnpm` keep PATH precedence.

**4. A model-facing `AGENTS.md`** that tells the agent what it is running in
and which tools it has: [agents/AGENTS.md](agents/AGENTS.md). It covers the
read-only rootfs, `python` vs `python3`, how to install more without root, the
shared Chromium on CDP `:9222`, and handing files over through Download buttons.
HolyClaude does the same thing by copying a variant-specific `CLAUDE.md` into
Claude Code's user memory on first boot. Here dsh's own mechanism is used:
since 0.2.1-alpha.2, dsh loads a shared user-global `$DSH_AGENTS_HOME/AGENTS.md`
after your `$DSH_HOME/AGENTS.md`. The image sets
`DSH_AGENTS_HOME=/opt/deepseek-harness-augmented/agents` (read-only, so it always
matches the image). Your own `~/.dsh/AGENTS.md` still loads first, and project
`AGENTS.md` files take precedence. To use a shared root of your own instead,
override `DSH_AGENTS_HOME`, e.g. `/workspace/.agents`. CI checks that every
command the file lists exists in the image.

## Run

```bash
DSH_WORKSPACE=/abs/path/to/project docker compose up -d
docker compose logs deepseek-harness | grep 'dsh web:'
```

[compose.yaml](compose.yaml) mirrors upstream's hardened service: loopback-only
ports, read-only rootfs, `cap_drop: ALL`, `no-new-privileges`. Pick a variant
with `DSH_AUGMENTED_TAG` (`latest`, `ungoogled`, or an immutable tag).

**Hosts without Landlock** (dsh's sandbox otherwise fails closed and every shell
call needs approval): use the bwrap variant and its overlay:

```bash
docker compose -f compose.yaml -f compose.bwrap.yaml up -d
```

[compose.bwrap.yaml](compose.bwrap.yaml) adds `seccomp=unconfined`,
`systempaths=unconfined` and `apparmor=unconfined` (a no-op without AppArmor);
capabilities stay dropped. On Ubuntu 23.10+ also set the host sysctl
`kernel.apparmor_restrict_unprivileged_userns=0`. History: we reported the
missing-Landlock case as runzhliu/deepseek-harness-docker#35, and upstream has
published the `-bwrap.N` variant since `0.2.1-alpha.1-r1`.

## How it stays up to date

```
Renovate (every 2h, self-hosted in Actions)
  └─ PR per update: upstream images (3 pins, one PR) · gh/yq/fzf/atuin (+ sha256 refresh)
                    · dsh plugins · npm CLIs · Python libs · Actions      + "Dependency Dashboard" issue
       └─ CI: static checks → build 3 variants × amd64+arm64 → smoke test each → `images`
            ├─ green → GitHub auto-merge → main CI (build + smoke)
            │            └─ if the PR changed an upstream image pin → publish the 3 variant tags + moving tags
            │               and create the GitHub Release (generated notes)
            └─ red   → issue [agent-fix] → maintainer-agent (self-hosted) pushes a fix
                                                            → CI green → issue closed → maintainer reviews + merges
Weekly rebuild (Mon 04:00 UTC) picks up Debian security updates and any tool/plugin bump merged meanwhile;
it publishes (and creates a release) only if some variant's image inventory changed.
Other merged bumps do not publish by themselves. To ship them sooner, cut a release by hand:

    gh release create "$(scripts/next-tag.sh)" --generate-notes

CI then builds that commit and publishes the three variant tags for that N (plus the moving tags). The tag must be
the next free `<X-rN>-augmented.<N>` and the commit must be on `main`; otherwise the run fails before pushing anything
(and the release you created stays, without images: delete it and retry). A release on an older commit of `main`
is published under its own tags but does not move the moving tags. Push, weekly and manual runs only ever publish the
tip of `main`, so re-running an old run cannot republish old code.

New issues ──► same agent, triage mode (sandboxed, offline, no token): investigates and posts one first answer
               (maintainer issues automatically; others after a maintainer adds the `triage` label)
               maintainer adds `agent-fix` ──► agent implements it on maintainer-agent/issue-<n> ──► draft PR for review

Agent-written code never auto-merges: the required `review-gate` check waits for a maintainer.
```

Upstream sometimes publishes the variants of a release at different times. The
grouped upstream PR stays red, because static-check requires all three pins
to name the same release, until every variant exists.

### Why Renovate and not Dependabot

Dependabot opens PRs only, never issues. It can't follow `FROM ${ARG}`
([dependabot-core#4597](https://github.com/dependabot/dependabot-core/issues/4597)),
binaries downloaded from GitHub Releases, or packages installed inline by a
Dockerfile. It also treats `-rc`/`-alpha` tags as prereleases. Renovate
handles all of these with one config, and its Dependency Dashboard issue gives
the issue-based overview.

## Development

See [AGENTS.md](AGENTS.md). In short: `scripts/static-check.sh --online`, then
`docker buildx build --load --build-arg VARIANT=default -t dsh-aug:default . && scripts/smoke.sh dsh-aug:default default`.

Setting up this repository or a fork from scratch (secrets, Renovate app,
branch protection): see [SETUP.md](SETUP.md).
