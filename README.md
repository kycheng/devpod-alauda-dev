# devpod-alauda-dev

DevPod configuration for Alauda-style development.

The repo is intentionally free of internal hostnames and credentials — those come from `$ACP_DAILY_ENTRY`, `$ACP_DEFAULT_USER`, `$ACP_DEFAULT_PASS`, etc., sourced at shell startup from `/workspaces/.claude/devpod.env` (gitignored, per-user).

## What's auto-installed (via `.devcontainer/post-create.sh`)

| Component | Path | Notes |
|---|---|---|
| Go 1.26.4 | `/usr/local/go` | Tarball install, SHA256-pinned. Replaces base image's Go 1.24 since the upstream image registry only publishes `:1.24`. |
| Claude Code | `/workspaces/.local/bin/claude` | Persistent across rebuilds via `/workspaces`. |
| kubectl | `/workspaces/.local/bin/kubectl` | Latest stable from `dl.k8s.io`. |
| code-server | `/workspaces/.local/bin/code-server` | Persistent install; auto-launched on port 8443. |
| tmux | system apt | Convenience. |
| zellij 0.44.3 | `/workspaces/bin/zellij` | Plus user config seeded from `.devcontainer/files/zellij/config.kdl` (never overwritten). |
| claude-discord-multisession | `/workspaces/claude-discord-multisession` | Cloned from upstream `github.com/danielfbm/claude-discord-multisession`, with local patches from `.devcontainer/files/claude-discord-multisession.patch` applied. |
| acp-kubeconfig-sync | `/workspaces/.local/bin/acp-kubeconfig-sync` | ACP login + per-cluster kubeconfig sync, used by the `acp-sync-daily` helper. |
| Node.js LTS | nvm-managed (image's `/usr/local/share/nvm/`) | Required by the Claude Code skills below; install is skipped if `current/bin/node` already resolves. |
| `humanizer-zh` skill | `~/.agents/skills/humanizer-zh` (symlinked into `/workspaces/.claude/skills/`) | 中文「去 AI 味」skill from `ai-zixun/humanizer-zh`. Installed via `npx skills add … -g`. |
| `claude-mem` plugin | `/workspaces/.claude/plugins/cache/thedotmack/claude-mem/` + state at `/workspaces/.claude-mem` (symlinked from `~/.claude-mem`) | Cross-session memory plugin from `thedotmack/claude-mem`. Installed via `npx claude-mem install --provider claude --no-auto-start`. |

## Shell helpers

Appended to `/workspaces/.bashrc` between `# --- BEGIN devpod-alauda-dev managed` / `# --- END` markers. Edits inside that block are overwritten on the next post-create run; edit outside freely.

| Helper | What it does |
|---|---|
| `mac <cmd>` | Run `<cmd>` on the user's local machine via the reverse SSH tunnel `ssh mac` (alias must be set up in `~/.ssh/config`). |
| `cc` | Shortcut for `/workspaces/.local/bin/claude`. |
| `acp-sync-daily` | Resolve current daily ACP via `$ACP_DAILY_ENTRY`, then sync `--cluster=$ACP_DEFAULT_CLUSTER` kubeconfig into `/workspaces/.kube/configs/`. Pass through any extra `acp-kubeconfig-sync` flags. Fails fast with a clear message if required env vars are missing. |

## Configuring secrets / internal addresses

Two per-user, per-environment things stay out of the repo:

### 1. `/workspaces/.claude/devpod.env`

The post-create script seeds this from `.devcontainer/files/devpod.env.example` if it's absent. Open it and fill in the values for your environment:

```sh
# Daily ACP rotating env entry point (302-redirects to the current daily)
export ACP_DAILY_ENTRY=http://<your-stable-daily-entry>/

# Default credentials for acp-kubeconfig-sync
export ACP_DEFAULT_USER=<user>
export ACP_DEFAULT_PASS=<pass>

# Optional: default cluster filter
export ACP_DEFAULT_CLUSTER=<cluster-name>
```

After editing, `source /workspaces/.claude/devpod.env` (or open a new shell) and run `acp-sync-daily` once to verify.

### 2. Other out-of-band files

| Path | Purpose |
|---|---|
| `/workspaces/.claude/edge.kubeconfig` | Long-lived Bearer token for an "edge" ACP. Format described in CLAUDE.md template. |
| `/workspaces/.claude/credentials.env` | Jira / Sonar / WeChat creds (sourced by bashrc). |
| `/workspaces/.claude/channels/discord/.env` | `DISCORD_BOT_TOKEN=...` for the discord multi-session plugin. Run `/discord:configure` inside a Claude Code session after dropping this in. |

## CLAUDE.md template

`.devcontainer/files/CLAUDE.md.template` is copied to `/workspaces/.claude/CLAUDE.md` only when that file does not already exist. To pull in template updates after first creation, diff the two manually.

## Tests

`.github/workflows/post-create-smoke.yml` runs on every PR touching `.devcontainer/**`. It spins up a container, runs `post-create.sh` cold, asserts the expected components are present, then re-runs to verify idempotency (managed bashrc block stays at exactly one occurrence, CLAUDE.md not overwritten, Go not re-downloaded).

**Container image** is resolved in this order:

1. `workflow_dispatch` input `base_image` — manual override when re-running from the Actions UI.
2. Repo variable `CI_BASE_IMAGE` — set under Settings → Variables → Actions (e.g. to an internal `build-harbor.alauda.cn/devcontainers/go:1.24` tag).
3. Default `mcr.microsoft.com/devcontainers/go:1.24` — public stand-in for the private harbor base.

For a private registry, also set secrets `CI_REGISTRY_USER` / `CI_REGISTRY_PASS` and uncomment the `credentials:` block in the workflow.

## Usage

```bash
devpod up github.com/kycheng/devpod-alauda-dev
```
