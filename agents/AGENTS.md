# Environment: DeepSeek Harness in a container (deepseek-harness-augmented)

You run inside the `louisremi/deepseek-harness-augmented` Docker image: the
community `runzhliu/deepseek-harness` image plus developer tooling. These
instructions come from the image itself (`$DSH_AGENTS_HOME/AGENTS.md`) and
describe what is installed. Project and personal instructions take precedence.

## The machine

- Debian trixie, user `node` (no root, no sudo). Capabilities are dropped.
- **Read-only root filesystem.** Writable: `/workspace` (the mounted project,
  also `$HOME`), `$DSH_HOME` (`/home/node/.dsh`, persistent Harness data) and
  `/tmp` (small tmpfs, mounted `noexec`: do not run binaries from it).
- `apt-get`, `sudo`, `npm install -g` and `pip install` into system or
  `/opt` paths all fail. See "Installing more" below.
- The user reaches you only through the browser. They cannot see this
  machine's screen or files, except through the Web UI and the noVNC desktop.

## Pre-installed command-line tools

Prefer these to writing ad-hoc scripts. Check versions with `--version`.

<!-- commands: smoke-tested, keep one command per backtick span -->
| Purpose | Commands |
| --- | --- |
| Search | `rg` (ripgrep), `fd`, `fzf`, `grep` |
| Files & data | `bat`, `tree`, `jq`, `yq` (Mike Farah's YAML/JSON/XML processor), `file`, `zip`, `unzip`, `rsync` |
| Version control | `git`, `gh` (GitHub CLI) |
| Shell & editing | `tmux`, `nano`, `shellcheck`, `atuin` (no shell integration configured) |
| Network | `curl`, `wget`, `dig`, `ip`, `ss`, `ssh` |
| Processes & debugging | `htop`, `ps`, `lsof`, `strace` |
| Databases (clients) | `psql`, `redis-cli`, `sqlite3`, `mysql`, `mysqldump` (MariaDB client) |
| Images | `convert`, `identify`, `mogrify` (ImageMagick) |
| Build | `gcc`, `g++`, `make`, `pkg-config` |
| Node.js & web | `node`, `npm`, `npx`, `pnpm`, `tsc`, `tsx`, `vite`, `esbuild`, `eslint`, `prettier`, `serve`, `nodemon`, `concurrently`, `dotenv`, `playwright` |
| Python | `python`, `pip`, `pytest`, `flake8`, `bandit`, `desloppify` |
<!-- /commands -->

- `gh` is not logged in. Ask the user for a token (`GH_TOKEN`) or to run
  `gh auth login`; never ask them to paste secrets into files you commit.
- Use `tmux` for long-running servers you need to keep alive while you work.
- `desloppify scan --path .` then `desloppify next` reviews code quality; it
  writes `.desloppify/` in the project (add it to `.gitignore`).

## Python: `python` vs `python3`

- `python` / `pip` are a virtualenv (`/opt/devtools/venv`) with requests,
  httpx, beautifulsoup4, lxml, Pillow, pandas, numpy, openpyxl, python-docx,
  jinja2, markdown, pyyaml, python-dotenv, rich, click, tqdm, aiohttp,
  aiomqtt, apprise, tree-sitter (+ language pack), playwright, pytest,
  pytest-asyncio, flake8 and bandit.
- `python3` is the bare system interpreter **without** those libraries.
  Run scripts that need them with `python`.
- The venv is read-only. For extra packages, create a project venv that
  still sees the bundled ones:
  `python -m venv --system-site-packages .venv && .venv/bin/pip install <pkg>`.

## Installing more

- Node: install per project (`npm install <pkg>`, `npx <pkg>`), never `-g`.
- Python: a project venv, as above.
- System packages: not possible at runtime. Tell the user what is missing
  (they can extend the image) instead of trying workarounds.
- Everything you install lives in `/workspace`: keep the project's
  `.gitignore` up to date (`node_modules/`, `.venv/`).

## Browser

- A persistent Chromium runs on a virtual display and is shared with the
  user's noVNC desktop (the "Browser desktop" button). Its DevTools endpoint
  is `http://127.0.0.1:9222`.
- To inspect or operate web pages, prefer the Browser Use tools when they are
  available. They drive that same Chromium, so the user can watch and take over.
- In scripts: Playwright (Node or Python) can attach with
  `connectOverCDP("http://127.0.0.1:9222")`, or launch its own headless
  browser with `executablePath` (`executable_path` in Python) set to
  `/usr/local/bin/chromium-docker`. Do not run `playwright install`: browser
  downloads are disabled and not needed.
- For one-off screenshots or PDFs: `chromium-docker --headless=new --screenshot=out.png <url>`.

## Sharing files with the user

The `@louisremi/dsh-always-on` plugin adds **Download** buttons to file cards,
a **Show files** button and an in-browser **Edit** button. To hand the user
a file, write it under `/workspace` and present it (file card), so they can
download it. Do not tell them to "open" a path on their computer.

## Optional plugins

`dshmarket` (community plugin market) and `dsh-plugin-subscriptions` (use
ChatGPT/Claude/Grok/Copilot subscriptions as model providers) are installed
but switched off. The user can enable them on the **Plugins** page. Mention
this only when relevant.
