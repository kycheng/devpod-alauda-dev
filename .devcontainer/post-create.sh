#!/bin/bash

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

# Install Claude Code to /workspaces/.local/bin
if [ ! -f /workspaces/.local/bin/claude ]; then
  echo "Installing Claude Code..."
  retry 5 5 bash -c 'export HOME=/workspaces && curl -fsSL https://claude.ai/install.sh | bash'
else
  echo "Claude Code already installed, skipping"
fi

# Install tmux
if ! command -v tmux &>/dev/null; then
  echo "Installing tmux..."
  sudo apt-get update && sudo apt-get install -y tmux
else
  echo "tmux already installed, skipping"
fi

# Install kubectl to /workspaces/.local/bin
if [ ! -f /workspaces/.local/bin/kubectl ]; then
  echo "Installing kubectl..."
  mkdir -p /workspaces/.local/bin
  retry 5 5 bash -c 'ARCH=$(uname -m); [ "$ARCH" = "aarch64" ] && ARCH=arm64 || ARCH=amd64; KVER=$(curl -sL https://dl.k8s.io/release/stable.txt); curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl" && install /tmp/kubectl /workspaces/.local/bin/kubectl && rm /tmp/kubectl'
else
  echo "kubectl already installed, skipping"
fi

echo "=== Setup Complete ==="
