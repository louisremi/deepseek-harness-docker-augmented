# Repository setup (one time)

Only needed when setting up this repository, or a fork of it, from scratch.
Day-to-day use is in [README.md](README.md); development is in
[AGENTS.md](AGENTS.md).

## Steps

1. **Docker Hub:** secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (access
   token with read/write). The first publish creates the public repository
   `louisremi/deepseek-harness-dev`.
2. **Renovate** runs as a private GitHub App of your own (Settings → Developer
   settings → GitHub Apps → New GitHub App):
   - Webhook: uncheck *Active* (the URL is then no longer required). No
     callback URL, no setup URL. *Only on this account*.
   - Repository permissions: Contents, Pull requests, Issues, Workflows,
     Commit statuses = read & write; Checks = read-only; Metadata = read-only
     (mandatory).
   - Create it, generate a private key, then **Install App** on this
     repository only. Without the installation, the workflow fails with
     `Not Found … get-a-repository-installation-for-the-authenticated-app`.

   Then set the variable `RENOVATE_APP_CLIENT_ID` (the app's Client ID), the
   secret `RENOVATE_APP_PRIVATE_KEY` (the `.pem` content), and the variable
   `RENOVATE_PR_AUTHOR` = `<app-slug>[bot]` so `review-gate` also checks who
   opened a PR. [renovate.yml](.github/workflows/renovate.yml) mints a
   one-hour token from them on each run.
3. **Settings:** enable *Allow auto-merge*. Add branch protection on `main`
   requiring the status checks `review-gate / gate`, `validate`,
   `build (amd64)` and `build (arm64)`, **including for administrators** (the
   agent's token is yours; without this it could push to `main` or merge past
   the checks).
4. **Environments** (Settings → Environments): create **`agent-review`** with
   *Required reviewers* = you, and leave *Prevent self-review* **off** (the
   agent's pushes are made with your PAT, so they count as yours). Create
   `no-review` with no rules (otherwise it is created on first use).
5. **Issue agent** (repair + triage):
   [maintainer-agent](https://github.com/louisremi/maintainer-agent). Add this
   repository to its host config; its behaviour here is set in
   [.github/maintainer-agent.yml](.github/maintainer-agent.yml).

## The same settings via `gh`

```bash
R=louisremi/deepseek-harness-docker-devkit
gh repo edit $R --enable-auto-merge --delete-branch-on-merge
gh secret set DOCKERHUB_USERNAME -R $R; gh secret set DOCKERHUB_TOKEN -R $R
gh variable set RENOVATE_APP_CLIENT_ID -R $R
gh variable set RENOVATE_PR_AUTHOR -R $R            # <app-slug>[bot]
gh secret set RENOVATE_APP_PRIVATE_KEY -R $R < ~/Downloads/<app-slug>.*.private-key.pem
gh api -X PUT repos/$R/branches/main/protection --input - <<'EOF'
{"required_status_checks":{"strict":false,"contexts":["review-gate / gate","validate","build (amd64)","build (arm64)"]},
 "enforce_admins":true,"required_pull_request_reviews":null,"restrictions":null}
EOF
me="$(gh api user --jq .id)"
gh api -X PUT repos/$R/environments/agent-review --input - <<EOF
{"reviewers":[{"type":"User","id":${me}}],"prevent_self_review":false}
EOF
gh api -X PUT repos/$R/environments/no-review
```

## Afterwards

With `enforce_admins` on, your own direct pushes to `main` are refused too.
Work through PRs. Only pure Renovate PRs pass `review-gate` on their own, so
approve your own PRs with one click on *Review deployments*.

To check the setup, run the Renovate workflow once by hand (Actions → Renovate
→ Run workflow, optionally with *Dry run*). PRs should appear as opened by
`<app-slug>[bot]`, pass `review-gate / gate` without approval, and auto-merge.
