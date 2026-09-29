#!/bin/bash

# Idempotent: safe to re-run; each block guards on existence/version.
# Files under .devcontainer/files/ are the source-of-truth artifacts shipped by this repo.

set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FILES_DIR="${SCRIPT_DIR}/files"

echo "=== DevContainer Post Create Setup ==="

# Retry helper: retry <max> <delay_seconds> <command...>
retry() {
  local max=$1; shift
  local delay=$1; shift
  for i in $(seq 1 "$max"); do
    "$@" && return 0
    echo "  Failed, retry ${i}/${max}..."
    sleep "$delay"
  done
  echo "  All retries failed, skipping"
  return 1
}

# --- Claude Code -----------------------------------------------------------
# Always run the installer: it fetches the latest release, so a rebuild also
# upgrades the persisted copy under /workspaces (the auto-updater only writes
# to $HOME, which does not survive rebuilds).
if [ -f /workspaces/.local/bin/claude ]; then
  echo "Updating Claude Code (current: $(/workspaces/.local/bin/claude --version 2>/dev/null))..."
else
  echo "Installing Claude Code..."
fi
retry 5 5 bash -c 'export HOME=/workspaces && curl -fsSL https://claude.ai/install.sh | bash'

# --- Codex CLI --------------------------------------------------------------
# Static musl binary from GitHub releases (no node in this image). Versioned
# under /workspaces/.local/share/codex/<tag>/ and symlinked into .local/bin.
# CODEX_HOME (config + login) lives in /workspaces/.codex via containerEnv.
install_codex() {
  local arch tag cur dir tmp
  case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "  unsupported arch $(uname -m)"; return 0 ;;
  esac
  tag=$(curl -fsSL --max-time 20 https://api.github.com/repos/openai/codex/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$tag" ] || { echo "  could not resolve latest codex release"; return 1; }
  cur=$(/workspaces/.local/bin/codex --version 2>/dev/null | awk '{print $NF}')
  if [ "rust-v${cur}" = "$tag" ]; then
    echo "Codex already at ${tag}, skipping"; return 0
  fi
  echo "Installing Codex ${tag} (current: ${cur:-none})..."
  dir=/workspaces/.local/share/codex/${tag}
  tmp=$(mktemp -d)
  curl -fsSL --retry 3 --max-time 900 -o "$tmp/codex.tar.gz" \
    "https://github.com/openai/codex/releases/download/${tag}/codex-${arch}-unknown-linux-musl.tar.gz" \
    && tar -xzf "$tmp/codex.tar.gz" -C "$tmp" \
    && mkdir -p "$dir" /workspaces/.local/bin \
    && install -m 755 "$tmp/codex-${arch}-unknown-linux-musl" "$dir/codex" \
    && ln -sfn "$dir/codex" /workspaces/.local/bin/codex
  local rc=$?
  rm -rf "$tmp"
  [ $rc -eq 0 ] && echo "  codex $(/workspaces/.local/bin/codex --version 2>/dev/null) installed"
  return $rc
}
retry 3 5 install_codex
# CODEX_HOME must be user-writable (codex creates tmp/ there on every run).
mkdir -p /workspaces/.codex
[ -O /workspaces/.codex ] || sudo chown -R "$(id -u):$(id -g)" /workspaces/.codex

# --- tmux ------------------------------------------------------------------
if ! command -v tmux &>/dev/null; then
  echo "Installing tmux..."
  sudo apt-get update && sudo apt-get install -y tmux
else
  echo "tmux already installed, skipping"
fi

# --- kubectl ---------------------------------------------------------------
if [ ! -f /workspaces/.local/bin/kubectl ]; then
  echo "Installing kubectl..."
  mkdir -p /workspaces/.local/bin
  retry 5 5 bash -c 'ARCH=$(uname -m); [ "$ARCH" = "aarch64" ] && ARCH=arm64 || ARCH=amd64; KVER=$(curl -sL https://dl.k8s.io/release/stable.txt); curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl" && install /tmp/kubectl /workspaces/.local/bin/kubectl && rm /tmp/kubectl'
else
  echo "kubectl already installed, skipping"
fi

# --- code-server (persistent install) --------------------------------------
if [ ! -f /workspaces/.local/bin/code-server ]; then
  echo "Installing code-server to /workspaces/.local..."
  mkdir -p /workspaces/.local/lib/code-server
  retry 5 5 bash -c 'curl -fsSL https://code-server.dev/install.sh | sh -s -- --prefix=/workspaces/.local'
else
  echo "code-server already installed, skipping"
fi

# --- Go (latest stable; in-place at /usr/local/go) -------------------------
GO_DESIRED=go1.26.4
GO_TARBALL=${GO_DESIRED}.linux-amd64.tar.gz
GO_SHA256=1153d3d50e0ac764b447adfe05c2bcf08e889d42a02e0fe0259bd47f6733ad7f
GO_CURRENT=$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')
if [ "$GO_CURRENT" != "$GO_DESIRED" ]; then
  echo "Upgrading Go: ${GO_CURRENT:-none} → $GO_DESIRED..."
  if retry 5 5 curl -fsSL --max-time 90 -o "/tmp/$GO_TARBALL" "https://go.dev/dl/$GO_TARBALL"; then
    actual=$(sha256sum "/tmp/$GO_TARBALL" | awk '{print $1}')
    if [ "$actual" = "$GO_SHA256" ]; then
      rm -rf /tmp/go-new && mkdir /tmp/go-new
      if tar -C /tmp/go-new -xzf "/tmp/$GO_TARBALL"; then
        sudo rm -rf /usr/local/go
        sudo mv /tmp/go-new/go /usr/local/go
        sudo chown -R "$USER:$USER" /usr/local/go 2>/dev/null || true
        echo "Go installed: $(/usr/local/go/bin/go version)"
      else
        echo "  tar extract failed, leaving existing Go in place"
      fi
    else
      echo "  SHA256 mismatch (expected $GO_SHA256, got $actual); leaving existing Go in place"
    fi
    rm -rf "/tmp/$GO_TARBALL" /tmp/go-new
  fi
else
  echo "Go $GO_DESIRED already installed, skipping"
fi

# --- zellij ----------------------------------------------------------------
ZELLIJ_VERSION=v0.44.3
if [ ! -f /workspaces/bin/zellij ]; then
  echo "Installing zellij $ZELLIJ_VERSION..."
  mkdir -p /workspaces/bin
  retry 5 5 bash -c "ARCH=\$(uname -m); [ \"\$ARCH\" = aarch64 ] && ARCH=aarch64 || ARCH=x86_64; \
    curl -fsSL -o /tmp/zellij.tar.gz \"https://github.com/zellij-org/zellij/releases/download/${ZELLIJ_VERSION}/zellij-\${ARCH}-unknown-linux-musl.tar.gz\" && \
    tar -C /tmp -xzf /tmp/zellij.tar.gz && \
    install /tmp/zellij /workspaces/bin/zellij && \
    rm /tmp/zellij.tar.gz /tmp/zellij"
else
  echo "zellij already installed, skipping"
fi
# Seed zellij config only if user has none
if [ ! -f "$HOME/.config/zellij/config.kdl" ] && [ -f "$FILES_DIR/zellij/config.kdl" ]; then
  echo "Seeding zellij config..."
  mkdir -p "$HOME/.config/zellij"
  cp "$FILES_DIR/zellij/config.kdl" "$HOME/.config/zellij/config.kdl"
fi

# --- claude-discord-multisession (clone upstream + apply local patch) ------
# Pin to the commit that files/claude-discord-multisession.patch was generated
# against so the patch always applies cleanly. Refresh both when you rebase.
PLUGIN_DIR=/workspaces/claude-discord-multisession
PLUGIN_COMMIT=525b89797a2871f2e3602cb9cc1e6bb87f1b0854
if [ ! -d "$PLUGIN_DIR/.git" ]; then
  echo "Cloning claude-discord-multisession (pinned to $PLUGIN_COMMIT)..."
  retry 3 5 git clone https://github.com/danielfbm/claude-discord-multisession.git "$PLUGIN_DIR"
  if [ -d "$PLUGIN_DIR/.git" ]; then
    git -C "$PLUGIN_DIR" checkout "$PLUGIN_COMMIT" 2>&1 | tail -2
    if [ -f "$FILES_DIR/claude-discord-multisession.patch" ]; then
      echo "Applying claude-discord-multisession.patch..."
      if git -C "$PLUGIN_DIR" apply --check "$FILES_DIR/claude-discord-multisession.patch" 2>/dev/null; then
        git -C "$PLUGIN_DIR" apply "$FILES_DIR/claude-discord-multisession.patch"
        echo "  Patch applied."
      else
        echo "  ERROR: patch does not apply at pinned commit $PLUGIN_COMMIT — refresh files/claude-discord-multisession.patch."
        exit 1
      fi
    fi
  fi
else
  echo "claude-discord-multisession already cloned, skipping (run 'cd $PLUGIN_DIR && git status' to inspect)"
fi

# --- acp-kubeconfig-sync ---------------------------------------------------
if [ -f "$FILES_DIR/acp-kubeconfig-sync" ]; then
  mkdir -p /workspaces/.local/bin /workspaces/.kube/configs
  install -m 755 "$FILES_DIR/acp-kubeconfig-sync" /workspaces/.local/bin/acp-kubeconfig-sync
  echo "acp-kubeconfig-sync installed at /workspaces/.local/bin/acp-kubeconfig-sync"
fi

# --- bridge-route ------------------------------------------------------------
# Manages which hosts auto-route through the $BRIDGE_HOST SOCKS5 bridge
# (bridge-up in bashrc.append): bridge-route {add|rm|list|sync} <host>.
if [ -f "$FILES_DIR/bridge-route" ]; then
  mkdir -p /workspaces/.local/bin
  install -m 755 "$FILES_DIR/bridge-route" /workspaces/.local/bin/bridge-route
  echo "bridge-route installed at /workspaces/.local/bin/bridge-route"
fi

# --- devpod.env (seed example if absent; never overwrite the live file) ----
DEVPOD_ENV=/workspaces/.claude/devpod.env
if [ ! -f "$DEVPOD_ENV" ] && [ -f "$FILES_DIR/devpod.env.example" ]; then
  echo "Seeding $DEVPOD_ENV from example (placeholder values — fill in for your env)..."
  mkdir -p /workspaces/.claude
  cp "$FILES_DIR/devpod.env.example" "$DEVPOD_ENV"
  chmod 600 "$DEVPOD_ENV"
elif [ -f "$DEVPOD_ENV" ]; then
  echo "$DEVPOD_ENV already exists, leaving it alone"
fi

# --- bashrc helpers (sentinel-guarded, idempotent) -------------------------
BASHRC=/workspaces/.bashrc
if [ -f "$BASHRC" ] && [ -f "$FILES_DIR/bashrc.append" ]; then
  if ! grep -q '# --- BEGIN devpod-alauda-dev managed' "$BASHRC"; then
    echo "Appending managed block to $BASHRC..."
    printf '\n' >> "$BASHRC"
    cat "$FILES_DIR/bashrc.append" >> "$BASHRC"
  else
    # Replace the existing managed block in-place to pick up updates.
    echo "Refreshing managed block in $BASHRC..."
    awk -v new="$FILES_DIR/bashrc.append" '
      BEGIN { skip = 0 }
      /^# --- BEGIN devpod-alauda-dev managed/ { skip = 1; while ((getline line < new) > 0) print line; close(new); next }
      /^# --- END devpod-alauda-dev managed/   { skip = 0; next }
      skip == 0 { print }
    ' "$BASHRC" > "$BASHRC.tmp" && mv "$BASHRC.tmp" "$BASHRC"
  fi
fi

# --- Seed CLAUDE.md if absent (never overwrite) ----------------------------
CLAUDE_MD=/workspaces/.claude/CLAUDE.md
if [ ! -f "$CLAUDE_MD" ] && [ -f "$FILES_DIR/CLAUDE.md.template" ]; then
  echo "Seeding $CLAUDE_MD from template..."
  mkdir -p /workspaces/.claude
  cp "$FILES_DIR/CLAUDE.md.template" "$CLAUDE_MD"
elif [ -f "$CLAUDE_MD" ]; then
  echo "$CLAUDE_MD already exists, leaving it alone (manual merge if you want template updates: diff with $FILES_DIR/CLAUDE.md.template)"
fi

echo "=== Setup Complete ==="
