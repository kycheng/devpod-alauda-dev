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
# Conversation resume: by default each session is started with
# `claude --resume <id>`, where <id> is the newest transcript in
# $CLAUDE_CONFIG_DIR/projects/<cwd-slug>/, so the pre-restart conversation
# comes back. --fresh starts empty sessions instead; --session <uuid> picks a
# specific transcript (only valid together with a single --only sid).
#
# Other pitfalls handled here (each one cost a manual restore before):
# - Run from inside Claude, the launched zellij/claude would inherit
#   CLAUDECODE / CLAUDE_CODE_* and the discord plugin never starts. All
#   CLAUDE* vars except CLAUDE_CONFIG_DIR are unset up front.
# - A `plugin:discord:discord` entry in mcp-needs-auth-cache.json makes new
#   sessions skip the plugin for 15 min; it is removed (with a backup).
# - zellij rejects session names longer than ~70 chars (socket path limit);
#   the display part is truncated, the trailing -<sid> is kept.
# - Success is checked in daemon.log (`register outcome=ok`), not assumed.
#
# Usage:
#   restore-sessions [--dry-run] [--only <sid>[,<sid>...]] [--skip-confirm]
#                    [--fresh] [--session <uuid>]
#   restore-sessions --find <text>   # list bindings whose cwd matches <text>

set -uo pipefail

BINDINGS=${BINDINGS_JSON:-/workspaces/.claude/channels/discord/bindings.json}
ZELLIJ=${ZELLIJ_BIN:-/workspaces/bin/zellij}
CLAUDE_BIN=${CLAUDE_BIN:-claude}
CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
DAEMON_LOG=${DAEMON_LOG:-$(dirname "$BINDINGS")/daemon.log}
NEEDS_AUTH_CACHE=$CONFIG_DIR/mcp-needs-auth-cache.json
MAX_SESSION_NAME=64

DRY=0
SKIP_CONFIRM=0
ONLY=""
FRESH=0
SESSION_ID=""
FIND=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --skip-confirm) SKIP_CONFIRM=1 ;;
    --only) shift; ONLY=$1 ;;
    --fresh) FRESH=1 ;;
    --session) shift; SESSION_ID=$1 ;;
    --find) shift; FIND=$1 ;;
    -h|--help)
      sed -n '2,41p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$FIND" ]; then
  jq -r --arg f "$FIND" 'to_entries[] | select(.value.cwd | contains($f))
    | "\(.key)\t\(.value.thread_id)\t\(.value.cwd)"' "$BINDINGS"
  exit 0
fi
if [ -n "$SESSION_ID" ] && { [ -z "$ONLY" ] || [[ "$ONLY" == *,* ]]; }; then
  echo "❌ --session needs exactly one --only <sid>" >&2; exit 2
fi

# Drop the caller's Claude session identity so the child Claude starts as a
# top-level session and loads its channel plugin.
for v in $(env | grep -oE '^CLAUDE[A-Z_]*' | sort -u); do
  [ "$v" = CLAUDE_CONFIG_DIR ] || unset "$v"
done

if [ "$DRY" != 1 ] && [ -f "$NEEDS_AUTH_CACHE" ] && \
   jq -e 'has("plugin:discord:discord")' "$NEEDS_AUTH_CACHE" >/dev/null 2>&1; then
  cp "$NEEDS_AUTH_CACHE" "$NEEDS_AUTH_CACHE.bak-$(date +%s)"
  tmp=$(mktemp)
  jq 'del(.["plugin:discord:discord"])' "$NEEDS_AUTH_CACHE" > "$tmp" && mv "$tmp" "$NEEDS_AUTH_CACHE"
  echo "🧹 removed plugin:discord:discord from $(basename "$NEEDS_AUTH_CACHE") (backup kept)"
fi

# Newest transcript id for a cwd, or empty. Claude stores transcripts under
# projects/<cwd with every non-alphanumeric char turned into '-'>/<uuid>.jsonl.
latest_transcript() {
  local slug dir
  slug=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')
  dir="$CONFIG_DIR/projects/$slug"
  [ -d "$dir" ] || return 0
  ls -t "$dir"/*.jsonl 2>/dev/null | head -1 | xargs -r basename | sed 's/\.jsonl$//'
}

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
    /dev/null </dev/null >/dev/null 2>&1 &
  # stdin must be /dev/null: otherwise the transient client forwards whatever
  # the caller's stdin carries (terminal keystrokes, piped output) into the
  # Claude prompt.
  sleep 3
  cpid=$(cat "$pidfile" 2>/dev/null)
  # Claude can take 10s+ to draw the prompt (longer when resuming a big
  # transcript), so sweep the panes for ~30s rather than once.
  for _ in $(seq 1 30); do
    # A dump that fails leaves the previous file in place; remove it first
    # so a stale screen never counts as "prompt seen".
    rm -f "$dump"
    env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" action dump-screen --path "$dump" 2>/dev/null
    # Match on the plugin identifier + footer — neither wraps across lines.
    if grep -q 'plugin:discord@danielfbm-discord' "$dump" 2>/dev/null && \
       grep -q 'Enter to confirm' "$dump" 2>/dev/null; then
      env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" action write-chars $'\r' 2>/dev/null
      sleep 2
      rm -f "$dump"
      env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" action dump-screen --path "$dump" 2>/dev/null
      if [ -s "$dump" ] && ! grep -q 'Enter to confirm' "$dump"; then
        sent=1; break
      fi
    fi
    env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" action focus-next-pane 2>/dev/null
    sleep 1
  done
  [ -n "$cpid" ] && kill -TERM -"$cpid" 2>/dev/null
  rm -f "$pidfile" "$dump"
  [ "$sent" = 1 ]
}

# Snapshot sessions once so the loop stays cheap. Track alive and EXITED
# separately — a session that exited (Claude crashed / dev-channels prompt
# rejected / plugin failed) is still listed by `zellij list-sessions` with
# an "(EXITED - attach to resurrect)" marker. Treating it as "already
# running" leaves the user with a dead pane; we want to force-clean it
# and relaunch instead.
sessions_raw=$(env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" list-sessions --no-formatting 2>/dev/null)
running_alive=$(printf '%s\n' "$sessions_raw" | grep -v 'EXITED' | awk '{print $1}')
running_exited=$(printf '%s\n' "$sessions_raw" | grep 'EXITED' | awk '{print $1}')

# zellij sometimes leaves an EXITED session behind that a single
# `delete-session --force` does not fully clean. Two-step it: kill-session
# (no-op if already dead) then delete-session --force. Safe to call on a
# missing name — both commands print an informational line and return 0.
purge_zellij_session() {
  env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" kill-session "$1" >/dev/null 2>&1 || true
  env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" delete-session --force "$1" >/dev/null 2>&1 || true
}

restore_one() {
  local sid=$1 cwd=$2 thread=$3
  if ! in_only "$sid"; then
    return
  fi
  if [ ! -d "$cwd" ]; then
    printf '  ⏭  %s  cwd missing: %s\n' "$sid" "$cwd"; return
  fi
  # Already alive?
  if printf '%s\n' "$running_alive" | grep -qE -- "-${sid}\$"; then
    local existing
    existing=$(printf '%s\n' "$running_alive" | grep -E -- "-${sid}\$" | head -1)
    printf '  ✓  %s  already running: %s\n' "$sid" "$existing"; return
  fi
  # An EXITED shell of the same sid? Clean it out before relaunching so
  # zellij accepts the new session name.
  if printf '%s\n' "$running_exited" | grep -qE -- "-${sid}\$"; then
    local dead
    dead=$(printf '%s\n' "$running_exited" | grep -E -- "-${sid}\$" | head -1)
    printf '  🧹 %s  purging EXITED session %s\n' "$sid" "$dead"
    purge_zellij_session "$dead"
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
  # "claude-" + base + "-" + 12-hex sid must fit zellij's name limit.
  local max_base=$(( MAX_SESSION_NAME - 8 - ${#sid} ))
  if [ "${#base}" -gt "$max_base" ]; then
    base=${base:0:$max_base}; base=${base%-}
  fi
  session="claude-${base}-${sid}"

  local resume_id="" resume_arg=""
  if [ "$FRESH" != 1 ]; then
    resume_id=${SESSION_ID:-$(latest_transcript "$cwd")}
    [ -n "$resume_id" ] && resume_arg="--resume $resume_id"
  fi

  if is_dm_cwd "$cwd"; then
    mode="dm"
  else
    mode="thread"
  fi

  printf '  ▶  %s  launching %s  (mode=%s, cwd=%s, thread=%s, resume=%s)\n' \
    "$sid" "$session" "$mode" "$cwd" "${thread:-pending}" "${resume_id:-fresh}"

  if [ "$DRY" = 1 ]; then return; fi

  # --resume goes before the variadic --dangerously-load-development-channels
  # flag, which would otherwise swallow it as a channel name.
  local claude_cmd="$CLAUDE_BIN $resume_arg --permission-mode bypassPermissions --dangerously-load-development-channels plugin:discord@danielfbm-discord"
  local cmd
  if [ "$mode" = "dm" ]; then
    # DM-mode: DISCORD_THREAD_ID/NAME MUST be unset for the shim to register
    # in mode=dm and receive channel-@ / DM traffic.
    cmd="$claude_cmd"
  else
    # Thread-mode: DISCORD_THREAD_ID=auto tells the daemon to reuse an
    # existing bindings.json entry for this sid rather than creating a new
    # thread, so this rebinds back to the stored thread_id.
    cmd="DISCORD_THREAD_ID=auto DISCORD_THREAD_NAME=$(printf %q "$display") $claude_cmd"
  fi
  local log_mark=0
  [ -f "$DAEMON_LOG" ] && log_mark=$(wc -l < "$DAEMON_LOG")

  local err
  if ! err=$(env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" attach --create-background "$session" 2>&1); then
    printf '     ❌ zellij could not create %s: %s\n' "$session" "$err"; return
  fi
  env -u ZELLIJ -u ZELLIJ_SESSION_NAME "$ZELLIJ" -s "$session" run \
    --close-on-exit --cwd "$cwd" -- bash -lc "$cmd" >/dev/null 2>&1

  printf '     ↳ launched. Attach with: zellij attach %s\n' "$session"

  if [ "$SKIP_CONFIRM" != 1 ]; then
    if confirm_plugin "$session"; then
      printf '     ↳ plugin prompt confirmed.\n'
    else
      printf '     ⚠ plugin prompt not seen in ~30s — attach manually and press Enter if it is still showing.\n'
    fi
  fi

  # The daemon logs one register line per shim start; only lines written
  # after this launch count.
  local line=""
  for _ in $(seq 1 30); do
    line=$(tail -n +"$((log_mark + 1))" "$DAEMON_LOG" 2>/dev/null \
      | grep "register outcome=.*session_id=${sid} " | tail -1)
    [ -n "$line" ] && break
    sleep 1
  done
  case "$line" in
    *outcome=ok*) printf '     ✅ %s\n' "${line#discord daemon: }" ;;
    "") printf '     ⚠ no register line in %s after 30s — attach and check /mcp\n' "$DAEMON_LOG" ;;
    *) printf '     ❌ %s\n' "${line#discord daemon: }" ;;
  esac
}

total=$(jq 'keys | length' "$BINDINGS")
echo "Found ${total} binding(s) in $BINDINGS"
[ "$DRY" = 1 ] && echo "(dry-run: no zellij sessions will be launched)"

while IFS=$'\t' read -r sid cwd thread; do
  restore_one "$sid" "$cwd" "$thread"
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value.cwd)\t\(.value.thread_id)"' "$BINDINGS")

echo "Done. Run 'zellij list-sessions' or '/discord:launch list' to verify."
