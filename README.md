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

## What's added on top of upstream

**1. SameSite=Lax session cookie** (all variants). With `Strict`, an installed
Android PWA can't log in, because it launches through an intent-initiated
navigation. The value is compiled into dsh, so a guarded build-time patch
rewrites it: an upstream change fails the build instead of shipping an
unpatched image.

**2. dsh plugins**, pre-installed in the `web` profile:

| Plugin | Default | What it does |
| --- | --- | --- |
| [@louisremi/dsh-always-on](https://github.com/louisremi/dsh-always-on) | **on** | The Harness runs remotely, so "show file location" and "Open in app" have no desktop to reach. This plugin replaces them with **Download file**, **Show files** (sidebar explorer) and an in-browser **Edit** button, and adds file management to the Files tree: **New file / New folder**, **Upload files** from your computer, **Rename or move**, **Delete** (to a `.tmp/deleted/` trash, with a 10-second **Restore**) and **Download as .zip** for folders. It also tells the Harness it has no desktop, so menus stop offering "Show in folder" and "Open in <app>". |
| [dshmarket](https://github.com/dsh-market/dsh-market) | off | Community plugin market. Seeded with `allowRestart: false`, because the container owns the lifecycle: restart the container instead. |
| [dsh-plugin-subscriptions](https://github.com/V1ki/dsh-plugin-subscriptions) | off | Use ChatGPT (Codex), Claude, Grok, Copilot and Antigravity subscriptions as model providers. |
| [@xbzbing/dsh-git-panel](https://github.com/xbzbing/dsh-git-panel) | off | IDE-style **Git** panel: branch and history graph, commit / amend / stage / discard, stash, tags and syntax-highlighted diffs, plus a branch marker in the input bar. It reads **and writes** the workspace repository, and its "AI suggest" button sends the diff to your configured model provider. |
| [@louisremi/dsh-oidc-login](https://github.com/louisremi/dsh-oidc-login) | **on** (inert until configured) | Sign in with an OpenID Connect provider (e.g. a self-hosted Pocket ID: passkey-only) instead of the launch-token link. Does nothing until `DSH_OIDC_ISSUER` is set; the token link always keeps working. See [Optional: sign in with Pocket ID](#optional-sign-in-with-pocket-id). |
| [dsh-plugin-chrome-controller](https://github.com/cyberofficial/dsh-plugin-chrome-controller) | off | `dsh_browser_*` tools that drive **your own Chrome** (tabs, clicks, typing, downloads) through a companion Chrome extension that pairs with DSH Web. The extension is not in the image: load the plugin's `extension` folder in Chrome and pair it from **Settings → Chrome browser**. Pairing over a remote DSH Web needs HTTPS. Its `dsh_browser_save_file` tool saves files fetched with a tab's signed-in session into the workspace, under `.tmp/downloads/`. |
| [@momojie-s/dsh-workspace-mcp](https://github.com/Momojie-S/dsh-workspace-mcp) | off | Loads **MCP servers per workspace**. A project's own `.dsh/mcp.servers.yml` (stdio or streamable-http servers, same fields as dsh's official MCP client) applies only to sessions whose working directory is that project; the tools are registered for the agent and removed with it, so projects never see each other's servers. It reconnects dropped servers automatically and reloads when the file changes. A project without the file loads nothing. **It starts the commands that file names**, so only enable it for projects you trust. |

Turn the "off" plugins on from the sidebar's **Plugins** page. They are
already installed, so this needs no network. A plugin that ships off may
declare DSH peer ranges that exclude the bundled dsh (currently
dsh-plugin-subscriptions). The build then records an exact-version exemption
so that it stays installable. **Enabling it is at your own risk** until its
author widens the range. A plugin that ships on must be compatible, or the
build fails.

dsh-git-panel is the one bundled plugin with a **Web client half**: its bundle
manifest is fixed when `dsh web` starts, so if the Git tab does not appear
after you enable it, restart the container (`docker compose restart`) and
refresh the page. Its peers match the bundled dsh, so no exemption is needed.

dsh-plugin-chrome-controller is not published to npm, so it is pinned to a
release commit of [cyberofficial's repository](https://github.com/cyberofficial/dsh-plugin-chrome-controller)
(`github:cyberofficial/dsh-plugin-chrome-controller#<sha>`). The extension
must match: load the `extension` folder of the same release
([v0.1.65](https://github.com/cyberofficial/dsh-plugin-chrome-controller/releases/tag/v0.1.65)).

dsh-workspace-mcp is not published to npm and has no releases, so it is pinned
to a Git commit (`github:Momojie-S/dsh-workspace-mcp#<sha>`) and built while
the image is built. Example `.dsh/mcp.servers.yml` in a project:

```yaml
servers:
  my-server:
    transport: stdio
    command: npx
    args: ["-y", "some-mcp-server@latest"]
  remote:
    transport: streamable-http
    url: https://example.com/mcp
```

Its tools appear as `mcp__<server>__<tool>`; a project server with the same
name as a global one shadows it for that project only.

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

**3. Developer tools** a coding agent reaches for daily, added to what
upstream already ships (git, curl, wget, jq, ripgrep, zip, unzip, rsync,
ssh, gcc/make, ImageMagick, Chromium, pnpm). Upstream's `dsh`, `node`,
`python3` and `pnpm` keep PATH precedence; everything below is appended.
AI coding-agent CLIs are out of scope on purpose.

_Debian packages_ (apt; the browser needs the emoji font):

| Tool | What it's for |
| --- | --- |
| `fd` | Fast file-name search |
| `bat` | `cat` with syntax highlighting |
| `tree` | Directory trees |
| `tmux` | Terminal multiplexer — keep servers running while you work |
| `nano` | Terminal editor |
| `shellcheck` | Shell-script linting |
| `dig` | DNS queries |
| `ip`, `ss` | Networking: interfaces, routes, sockets |
| `strace` | System-call tracing |
| `lsof` | Open files and network sockets per process |
| `htop` | Process monitor |
| `psql` | PostgreSQL client |
| `redis-cli` | Redis client |
| `sqlite3` | SQLite client |
| `mysql`, `mysqldump` | MySQL clients (Debian's MariaDB) |
| `pkg-config` | Build-time library discovery |

_Release binaries_, sha256-pinned per architecture:

| Tool | What it's for |
| --- | --- |
| `gh` | GitHub CLI: PRs, issues, releases from the terminal |
| `yq` | Mike Farah's YAML/JSON/XML processor |
| `fzf` | Fuzzy finder |
| `atuin` | Shell-history client (installed without account setup or shell integration) |

_npm CLIs_ (`/opt/devtools/npm`, pinned by lockfile):

| Tool | What it's for |
| --- | --- |
| `tsc`, `tsx` | TypeScript compilation and execution |
| `vite`, `esbuild` | Fast build tools |
| `eslint`, `prettier` | Code quality and formatting |
| `serve` | Static file server |
| `nodemon` | Auto-restarting dev server |
| `concurrently` | Run multiple scripts in parallel |
| `dotenv` | Load env vars from `.env` files |
| `playwright` | Browser automation, Node and Python; uses upstream's Chromium |

_Python libraries_ (venv at `/opt/devtools/venv`; it is the `python`/`pip`
on PATH, while `python3` stays upstream's bare interpreter):

| Package | What it's for |
| --- | --- |
| `requests`, `httpx` | HTTP clients |
| `aiohttp`, `aiomqtt` | Async HTTP and MQTT clients |
| `beautifulsoup4`, `lxml` | HTML/XML parsing |
| `Pillow` | Image processing (pre-compiled) |
| `pandas`, `numpy` | Data manipulation (pre-compiled) |
| `openpyxl` | Read/write Excel files |
| `python-docx` | Read/write Word documents |
| `defusedxml` | Hardened XML parsing |
| `jinja2`, `markdown` | Templating and markdown rendering |
| `pyyaml`, `python-dotenv` | Config-file parsing |
| `rich`, `click`, `tqdm` | Pretty CLIs and progress bars |
| `pytest`, `pytest-asyncio`, `flake8` | Python tests, async tests, linting |
| `desloppify` | Code-quality review (`scan`, then `next`); writes `.desloppify/` |
| `bandit` | Python security checks |
| `tree-sitter` (+ language pack) | Parser-backed code analysis |
| `playwright` | Browser automation (pairs with the npm one) |
| `apprise` | Notifications (library and `python -m apprise`; the `apprise` CLI is not on PATH) |

**4. A model-facing `AGENTS.md`** that tells the agent what it is running in
and which tools it has: [agents/AGENTS.md](agents/AGENTS.md). It covers the
read-only rootfs, `python` vs `python3`, how to install more without root, the
shared Chromium on CDP `:9222`, and handing files over through Download buttons.
The mechanism is dsh's own:
since 0.2.1-alpha.2, dsh loads a shared user-global `$DSH_AGENTS_HOME/AGENTS.md`
after your `$DSH_HOME/AGENTS.md`. The image sets
`DSH_AGENTS_HOME=/opt/deepseek-harness-augmented/agents` (read-only, so it always
matches the image). Your own `~/.dsh/AGENTS.md` still loads first, and project
`AGENTS.md` files take precedence. To use a shared root of your own instead,
override `DSH_AGENTS_HOME`, e.g. `/workspace/.agents`. CI checks that every
command the file lists exists in the image.

## Scratch files and `/tmp`

Under the bwrap sandbox (the `bwrap` variant, or any host where dsh falls back
to bubblewrap) every tool call runs in a fresh cage with its own empty `/tmp`:
a file the agent writes to `/tmp` is gone by its next call. The container's
`/tmp` is also small and `noexec`. Setting `TMPDIR=/workspace/.tmp` does not
help, because inside the cage only the session's project directory is
writable; `/workspace` itself is read-only.

So every variant sets `BASH_ENV=/opt/deepseek-harness-augmented/augmented-bash-env`
([scripts/augmented-bash-env](scripts/augmented-bash-env)). bash sources it
before each tool call. It points `TMPDIR` at `<project>/.tmp` (the topmost
writable directory between `$HOME` and the current directory), creating it if
needed, with an empty `.dsh-tmpdir` marker from its write test. It persists,
works from subdirectories, and allows executables. It leaves `TMPDIR` alone
when that is already a writable directory, and does nothing outside
`$HOME/<project>`. Upstream sets `HOME=/workspace`, the workspace mount; if
you mount projects elsewhere, set `HOME` to that mount point too. Add `.tmp/`
to your projects' `.gitignore`; the model-facing AGENTS.md tells the agent the
same.

**Your own `BASH_ENV` replaces ours.** If you set `BASH_ENV` (e.g. to an
environment file on a tools volume), source ours from it:

```bash
. /opt/deepseek-harness-augmented/augmented-bash-env
```

Source it instead of keeping a `TMPDIR` fallback of your own, not in addition
to one placed earlier: ours leaves an already-writable `TMPDIR` alone, so the
first fallback wins. Also make your file safe under `set -u`: agents often run
`bash -euo pipefail`, which aborts sourcing at the first unset variable (write
`${LD_LIBRARY_PATH:-}`, not `$LD_LIBRARY_PATH`), so everything after it,
`TMPDIR` included, is silently skipped.

**Leave `TMPDIR` out of your compose.** It does not reach the agent's shell,
because the script replaces it on every call. It does move the files of the
dsh server itself, which runs outside the cage: `dsh-workspace-changes-*`,
`dsh-spill-*` and similar, which can be hundreds of MB each. Unset, those go to
the container's 512 MB `/tmp`, which is what the examples above do and what
upstream does. Setting it to a directory on a share trades a bounded in-memory
budget for unbounded files that nothing prunes. If `/tmp` fills up, give that
tmpfs more room (`size=2g` in the `tmpfs:` entry) and watch it with
`docker exec <container> df -h /tmp`.

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

### Running as another user (e.g. Unraid `99:100`)

The image runs as `node` (uid 1000). To have the files the agent writes land
with your share's ownership, you can override `user:`. Three things then need
to follow, all verified on Unraid with `user: "99:100"`:

- **Move the Harness home.** The default `/home/node/.dsh` sits under a
  `drwx------` home owned by uid 1000, which another uid cannot enter, and the
  read-only rootfs means you cannot fix that at runtime. Set `DSH_HOME` to a
  volume of your own (mount it there instead of at `/home/node/.dsh`), and
  `NPM_CONFIG_CACHE` under it, and make the volume writable by your uid with a
  one-shot init container:

  ```yaml
  deepseek-harness-init:
    image: alpine:3
    user: "0:0"
    restart: "no"
    volumes: [dsh-home:/dsh]
    command: ["chown", "-R", "99:100", "/dsh"]
  deepseek-harness:
    user: "99:100"
    depends_on:
      deepseek-harness-init: { condition: service_completed_successfully }
    volumes: [dsh-home:/dsh, ...]
    environment:
      DSH_HOME: /dsh
      NPM_CONFIG_CACHE: /dsh/npm-cache
      SHELL: /bin/bash
  ```

- **Set `SHELL`.** Your uid has no `/etc/passwd` entry in the image. With
  `SHELL` unset, dsh asks the system for the user's login shell, and every
  sidebar terminal (**New terminal**, and plugins that open one) fails with
  `Could not open a sidebar terminal: … uv_os_get_passwd returned ENOENT`.
  `SHELL=/bin/bash` (or `/bin/sh`) avoids the lookup.
- **Expect other user lookups to fail.** Tools that need a passwd entry refuse
  to run, for instance `ssh` (`No user exists for uid 99`). Workarounds such as
  an `LD_PRELOAD` shim faking the entry are outside this image.

### Behind a reverse proxy, or with the desktop off

- **Reverse proxy** (Tailscale, Caddy, …): dsh checks the `Host`/`Origin`
  header, so add `--trusted-host <public name>` to `command:`. Restating
  `command:` replaces the image's `CMD`, so keep its arguments too:
  `["web", "--patch", "/opt/deepseek-harness/web.cordis.patch.yml", "--no-open", "--trusted-host", "<public name>"]`.
- **`DSH_DESKTOP_ENABLED=0`** turns off Xvfb, Chromium and noVNC, so ports 6080
  and 9222 never listen and [compose.yaml](compose.yaml)'s healthcheck stays
  unhealthy. Probe the web port alone:

  ```yaml
  healthcheck:
    test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3080/').then(r => process.exit(r.status === 401 ? 0 : 1)).catch(() => process.exit(1))"]
  ```

## Optional: sign in with Pocket ID

By default you open dsh with the `?token=` link printed in the container logs.
To sign in from any device (including the installed PWA) through a real login,
run a self-hosted [Pocket ID](https://pocket-id.org) next to dsh. The bundled
[dsh-oidc-login](https://github.com/louisremi/dsh-oidc-login) plugin redirects
your browser to Pocket ID and, once Pocket ID vouches for you, hands the browser
**dsh's own session cookie**, the same one the token link gives. Nothing in dsh
is patched, and the token link keeps working (use it if Pocket ID is down).

Pocket ID is passkey-only and needs **no SMTP and no one-time codes**. The
account, the OIDC client and its secret are registered through Pocket ID's own
API, so the only manual step left is the passkey itself — which WebAuthn
requires a human and an authenticator for.

```bash
scripts/pocket-id-setup.sh ./pocket-id     # data dir + three generated secrets
cp .env.pocket-id.example .env             # then edit the URLs, e-mail, uid/gid
docker compose -f compose.yaml -f compose.pocket-id.yaml up -d
docker compose -f compose.yaml -f compose.pocket-id.yaml run --rm pocket-id-bootstrap
```

The bootstrap prints one link. Open it, click **Add Passkey**, and you are in
dsh. It is idempotent: re-run it any time for a fresh link (for example after
losing a device), and it reuses the existing account, client and secret. It
creates:

- the owner account from `DSH_AUTH_OWNER` / `DSH_OIDC_ALLOWED_EMAILS`, as an
   admin whose e-mail is already verified (Pocket ID only sets that on sign-up,
  so doing it here matters: dsh-oidc-login refuses an identity its provider
  marks unverified);
- the `dsh` OIDC client (confidential, callback
  `https://<DSH_OIDC_PUBLIC_URL>/auth/callback`, **All Users**), so no client
  ID has to be copied anywhere — `compose.pocket-id.yaml` sets it to `dsh`;
- that client's secret, from `pocket-id/secrets/dsh_oidc_client_secret`, a
  file `scripts/pocket-id-setup.sh` generated. Pocket ID only keeps its hash.

How it talks to Pocket ID: `STATIC_API_KEY_FILE` gives Pocket ID a fixed admin
API key (`pocket_id/secrets/pocket_id_api_key`). Only the `pocket-id-bootstrap`
one-shot container mounts it — never the dsh container, whose agent runs with
your authority. The bootstrap uses the dsh image itself (`curl` and `jq` are
already there), so there is no extra image to trust.

Keep a second device (or a hardware key) enrolled as a backup passkey: **there
is no password and no recovery e-mail**, so losing every passkey locks you out
of Pocket ID (the dsh token link still gets you into dsh).


What the overlay enforces:

| Setting | Value | Why |
| --- | --- | --- |
| `ALLOW_USER_SIGNUPS` | `disabled` | only the admin creates accounts; no public sign-up |
| `EMAILS_VERIFIED` | `true` | dsh-oidc-login refuses an identity its provider marks unverified, and Pocket ID defaults this to `false` |
| `ANALYTICS_DISABLED`, `VERSION_CHECK_DISABLED` | `true` | no telemetry, no GitHub update checks |
| `TRUST_PROXY` | `true` | TLS is terminated in front of the container |
| `ENCRYPTION_KEY_FILE` | Docker secret | the key never appears in the environment or the compose file |
| container | `read_only`, `cap_drop: ALL`, `no-new-privileges`, loopback port | same posture as the dsh container |

**Sign out:** the plugin's own **Sign out** row sits at the end of
**Settings → General** and links to `/auth/logout` (it appears only when the
plugin is configured). dsh has no server-side session store, so that clears
this browser's cookie only.

Notes from a real deployment (each of these cost us a debugging session):

- **Finish the passkey before leaving `/setup`.** Pocket ID closes the setup
  page as soon as the first account exists. If the passkey step fails (for
  example in a browser without a platform authenticator, such as the in-app
  noVNC desktop), you are left with an account that cannot authenticate, and
  the fix is to stop the container, move `data/` aside and start over — or use
  the bootstrap service, which creates the account and prints a login link
  instead of the setup form.
- **`EMAILS_VERIFIED` only covers sign-ups.** The account created at `/setup`
  keeps `email_verified: false` until the address is ticked in
  **Administration → Users**; the bootstrap sets `emailVerified: true` itself.
  The plugin refuses an identity its provider marks unverified
  (`… is not verified by the provider`), and
  `DSH_OIDC_REQUIRE_VERIFIED_EMAIL=0` relaxes that check.
- **Container user:** the overlay runs Pocket ID as `DSH_AUTH_UID:DSH_AUTH_GID`
  (99:100 on Unraid). Starting it as root instead makes the image entrypoint
  create a user and `su-exec` into it, which `cap_drop: ALL` refuses
  (`su-exec: setgroups(100): Operation not permitted`).
- **Replacing the proxy's container:** if you swap the container behind a
  tsdproxy name, tsdproxy may keep the old proxy stopped. `docker restart
  tsdproxy` makes it re-scan; the node keeps its address and approval.
- **Unraid:** keep Pocket ID's `data` directory off `/mnt/user` (shfs/FUSE);
  use `DSH_AUTH_DATA_DIR=/mnt/cache/appdata/pocket-id/data`. The `secrets`
  directory is fine on the share.
- **tsdproxy** provisions one Tailscale node per proxied service. The first
  start of the proxy prints a one-time approval link in `docker logs tsdproxy`
  (`https://login.tailscale.com/a/…`): open it, or the name never resolves.
  Note the node's address (`tailscale status | grep <proxy name>`); dsh has no
  MagicDNS in its container, so it must reach the name explicitly:

  ```yaml
  extra_hosts:
    - "id.example.com:<proxy node tailnet IP>"
  ```

  The address is stable while the node key survives (tsdproxy keeps its state
  in `/data`); if the node is ever deleted and re-approved, update it.
- dsh has no server-side session store: logout clears the current browser's
  cookie only. To revoke every dsh session, delete the
  `client-connection/browser-session` entry from `/home/node/.dsh/.credentials.yaml`
  and restart the container.
- The noVNC port 6080 has no authentication of its own: never publish it.
- An existing `web` profile (created by an earlier image) does not get the
  plugin automatically; the container logs print the
  `dsh plugin --profile web add @louisremi/dsh-oidc-login@<version>` command.

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
