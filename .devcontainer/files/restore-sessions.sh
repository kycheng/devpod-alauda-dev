#!/bin/bash
# Restore claude-discord-multisession zellij sessions from bindings.json.
#
# After a devpod restart, every in-memory zellij + Claude session dies but
# bindings.json (persisted on /workspaces) still has the (sid, cwd, thread_id)
# for each pre-existing session. This script re-launches each of them in the
# same cwd so they re-bind to the same Discord thread, then confirms the
# --dangerously-load-development-channels plugin prompt so Claude actually
# finishes loading and registers with the daemon.
#
# Idempotent: if a zellij session already exists for a given sid, skip it.
# Safe: sessions whose cwd no longer exists are skipped with a warning.
#
# By default DM-mode sessions (cwd == /workspaces or /workspaces/.claude) are
# launched without DISCORD_THREAD_ID / DISCORD_THREAD_NAME so the shim
# registers in DM mode instead of thread mode — matches the pre-restart shape
# recorded in daemon.log.
#
# Usage:
#   restore-sessions [--dry-run] [--only <sid>[,<sid>...]] [--skip-confirm]

set -uo pipefail

BINDINGS=${BINDINGS_JSON:-/workspaces/.claude/channels/discord/bindings.json}
ZELLIJ=${ZELLIJ_BIN:-/workspaces/bin/zellij}
CLAUDE_BIN=${CLAUDE_BIN:-claude}

DRY=0
SKIP_CONFIRM=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --skip-confirm) SKIP_CONFIRM=1 ;;
    --only) shift; ONLY=$1 ;;
    -h|--help)
      sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f "$BINDINGS" ]; then
  echo "❌ bindings.json missing: $BINDINGS" >&2; exit 1
fi
if ! command -v jq >/dev/null; then
  echo "❌ jq required but not on PATH" >&2; exit 1
fi
if [ ! -x "$ZELLIJ" ]; then
  echo "❌ zellij not executable: $ZELLIJ (override with ZELLIJ_BIN=)" >&2; exit 1
fi

# DM-mode cwds — launched without DISCORD_THREAD_ID/NAME so the shim
# registers in mode=dm. Everything else registers in mode=thread.
# Only /workspaces itself is DM-mode; /workspaces/.claude used to be but
# daemon.log shows its recent registrations were all mode=thread.
is_dm_cwd() {
  case "$1" in
    /workspaces) return 0 ;;
    *) return 1 ;;
  esac
}

in_only() {
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

# Attach a transient pty-backed client, dismiss the Claude
# --dangerously-load-development-channels plugin-approval prompt by pressing
# Enter on the highlighted option, then detach. Walks up to 4 panes because
# the launch flow leaves an idle default shell pane focused; the Claude pane
# is somewhere else.
#
# Delivery quirks (learned the hard way):
# - Claude Code's Ink UI reads raw CR ('\r'), not LF ('\n'). Sending '\n'
#   silently no-ops the confirmation.
# - `action send-keys` is for named key sequences and re-encodes bytes;
#   `action write-chars` writes the literal bytes we want to the pane's
#   stdin. Only `write-chars` reaches Ink.
# - Verify by re-dumping after the write. If the sentinel is still there,
#   the pane focus was wrong; cycle and try again.
confirm_plugin() {
  local session=$1 pidfile dump cpid sent=0
  pidfile=$(mktemp); dump=$(mktemp)
  SHELL=/bin/bash setsid script -qfc \
    "bash -c 'echo \$\$ > $pidfile; exec env -u ZELLIJ -u ZELLIJ_SESSION_NAME $ZELLIJ attach $session'" \
    /dev/null >/dev/null 2>&1 &
  sleep 3
  cpid=$(cat "$pidfile" 2>/dev/null)
  for _ in 1 2 3 4; do
    env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" action dump-screen --path "$dump" 2>/dev/null
    # Match on the plugin identifier + footer — neither wraps across lines.
    if grep -q 'plugin:discord@danielfbm-discord' "$dump" 2>/dev/null && \
       grep -q 'Enter to confirm' "$dump" 2>/dev/null; then
      env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" action write-chars $'\r' 2>/dev/null
      sleep 2
      env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" action dump-screen --path "$dump" 2>/dev/null
      if ! grep -q 'Enter to confirm' "$dump" 2>/dev/null; then
        sent=1; break
      fi
    fi
    env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" action focus-next-pane 2>/dev/null
    sleep 0.3
  done
  [ -n "$cpid" ] && kill -TERM -"$cpid" 2>/dev/null
  rm -f "$pidfile" "$dump"
  [ "$sent" = 1 ]
}

# Snapshot running sessions once so the loop stays cheap.
running=$(env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" list-sessions --no-formatting 2>/dev/null | awk '{print $1}')

restore_one() {
  local sid=$1 cwd=$2 thread=$3
  if ! in_only "$sid"; then
    return
  fi
  if [ ! -d "$cwd" ]; then
    printf '  ⏭  %s  cwd missing: %s\n' "$sid" "$cwd"; return
  fi
  # Already running?
  if printf '%s\n' "$running" | grep -qE -- "-${sid}\$"; then
    local existing
    existing=$(printf '%s\n' "$running" | grep -E -- "-${sid}\$" | head -1)
    printf '  ✓  %s  already running: %s\n' "$sid" "$existing"; return
  fi

  # Compute display name: repo basename if inside a git working tree,
  # otherwise the cwd basename. Matches the launch skill's derivation.
  local display base session mode
  if repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
    display=$(basename "$repo")
  else
    display=$(basename "$cwd")
  fi
  base=$(printf '%s' "$display" | sed 's/[^A-Za-z0-9_-]/-/g')
  session="claude-${base}-${sid}"

  if is_dm_cwd "$cwd"; then
    mode="dm"
  else
    mode="thread"
  fi

  printf '  ▶  %s  launching %s  (mode=%s, cwd=%s, thread=%s)\n' \
    "$sid" "$session" "$mode" "$cwd" "${thread:-pending}"

  if [ "$DRY" = 1 ]; then return; fi

  local cmd
  if [ "$mode" = "dm" ]; then
    # DM-mode: DISCORD_THREAD_ID/NAME MUST be unset for the shim to register
    # in mode=dm and receive channel-@ / DM traffic.
    cmd="$CLAUDE_BIN --dangerously-load-development-channels plugin:discord@danielfbm-discord"
  else
    # Thread-mode: DISCORD_THREAD_ID=auto tells the daemon to reuse an
    # existing bindings.json entry for this sid rather than creating a new
    # thread, so this rebinds back to the stored thread_id.
    cmd="DISCORD_THREAD_ID=auto DISCORD_THREAD_NAME=$(printf %q "$display")"
    cmd="$cmd $CLAUDE_BIN --dangerously-load-development-channels plugin:discord@danielfbm-discord"
  fi

  env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" attach --create-background "$session" >/dev/null 2>&1
  env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" run \
    --close-on-exit --cwd "$cwd" -- bash -lc "$cmd" >/dev/null 2>&1

  printf '     ↳ launched. Attach with: zellij attach %s\n' "$session"

  if [ "$SKIP_CONFIRM" != 1 ]; then
    sleep 4
    if confirm_plugin "$session"; then
      printf '     ↳ plugin prompt confirmed.\n'
    else
      printf '     ⚠ plugin prompt not seen in 4 pane sweeps — attach manually and press Enter if it is still showing.\n'
    fi
  fi
}

total=$(jq 'keys | length' "$BINDINGS")
echo "Found ${total} binding(s) in $BINDINGS"
[ "$DRY" = 1 ] && echo "(dry-run: no zellij sessions will be launched)"

while IFS=$'\t' read -r sid cwd thread; do
  restore_one "$sid" "$cwd" "$thread"
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value.cwd)\t\(.value.thread_id)"' "$BINDINGS")

echo "Done. Run 'zellij list-sessions' or '/discord:launch list' to verify."
