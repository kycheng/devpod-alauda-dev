# devpod-alauda-dev

Personal DevPod configuration for Alauda development.

## What's included (auto-installed via `.devcontainer/post-create.sh`)

| Component | Path | Notes |
|---|---|---|
| Go 1.26.4 | `/usr/local/go` | Replaces base image's Go 1.24 (image registry only has the `:1.24` tag). |
| Claude Code | `/workspaces/.local/bin/claude` | Persistent across rebuilds via `/workspaces`. |
| kubectl | `/workspaces/.local/bin/kubectl` | Latest stable from `dl.k8s.io`. |
| code-server | `/workspaces/.local/bin/code-server` | Persistent install; auto-launched on port 8443. |
| tmux | system apt | Convenience. |
| zellij 0.44.3 | `/workspaces/bin/zellij` | Plus user config seeded from `.devcontainer/files/zellij/config.kdl`. |
| claude-discord-multisession | `/workspaces/claude-discord-multisession` | Cloned from `github.com/danielfbm/claude-discord-multisession`, with local patches from `.devcontainer/files/claude-discord-multisession.patch` applied. |
| acp-kubeconfig-sync | `/workspaces/.local/bin/acp-kubeconfig-sync` | ACP login + per-cluster kubeconfig sync, used by `acp-sync-daily`. |

## Shell helpers (added to `/workspaces/.bashrc` between sentinel markers)

| Helper | What it does |
|---|---|
| `mac <cmd>` | Run `<cmd>` on the user's local Mac via the reverse SSH tunnel `ssh mac`. Set up the Mac side separately (`ssh -R 2223:localhost:22 ...`). |
| `cc` | Shortcut for `/workspaces/.local/bin/claude`. |
| `acp-sync-daily` | Resolve current daily ACP via `daily-devops.alaudatech.net`, then sync `--cluster=kychen` kubeconfig into `/workspaces/.kube/configs/`. Pass through any extra `acp-kubeconfig-sync` flags. |

The managed block is delimited by `# --- BEGIN devpod-alauda-dev managed` / `# --- END devpod-alauda-dev managed`. Edits inside the block will be overwritten on the next post-create run; edit outside the block freely.

## CLAUDE.md template

`.devcontainer/files/CLAUDE.md.template` is copied to `/workspaces/.claude/CLAUDE.md` **only if that file does not already exist**. To pull in template updates after first creation, diff the two files manually and merge.

## Secrets / out-of-band setup

The following must be configured per devpod by the user; they are intentionally **not** shipped with this repo:

- `/workspaces/.claude/edge.kubeconfig` — long-lived Bearer token for `edge.alauda.cn` (see the Edge cluster section in the CLAUDE.md template for the format).
- `/workspaces/.claude/credentials.env` — Jira / Sonar / WeChat creds (sourced by `~/.bashrc`).
- `/workspaces/.claude/channels/discord/.env` — `DISCORD_BOT_TOKEN=...` for the discord multi-session plugin. After dropping this in, run `/discord:configure` inside a Claude Code session.

## Usage

```bash
devpod up github.com/kycheng/devpod-alauda-dev
```

(Repo is private; `devpod` uses the `gh` credential helper.)
