#!/usr/bin/env bash
# auto-repair-tracker.sh — failure-hook script (v0.18.0+)
#
# Invoked by the stats-widget app's hook system whenever a tracker's
# scheduled scrape fails. Spawns a Claude Code agent in its own Terminal
# window pointed at the failing tracker and asks the agent to re-identify
# the broken element via the embedded MCP server.
#
# Required env vars (injected by HookExecutor.makeEnvironment):
#   TRACKER_ID, TRACKER_NAME, TRACKER_URL, TRACKER_SELECTOR
#   ERROR_KIND, ERROR_MESSAGE
#   CONSECUTIVE_FAILURE_COUNT
#   APP_GROUP_IDENTIFIER, MCP_SOCKET_PATH
#
# Failure mode: if Terminal.app isn't installed or AppleScript is denied
# by TCC, the script logs to /tmp/macos-widgets-stats-auto-repair.log
# and exits non-zero — HookExecutor records the failure in lastRun.detail
# so the user can see it in the Hooks panel.
#
# The agent is expected to (a) call repair_tracker / update_tracker on
# the embedded MCP server to fix the selector, then (b) send a macOS
# notification with the literal title "element reidentified by agent" so
# the user sees the action even if they weren't watching the Terminal
# window. See AUTO_REPAIR_PROMPT below for the exact instruction.

set -euo pipefail

LOG_FILE="/tmp/macos-widgets-stats-auto-repair.log"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" >>"$LOG_FILE"
}

log "auto-repair-tracker.sh fired for tracker ${TRACKER_NAME:-?} (${TRACKER_ID:-?})"
log "  url=${TRACKER_URL:-?} selector=${TRACKER_SELECTOR:-?} error=${ERROR_MESSAGE:-?}"

# Locate Claude Code on PATH or in well-known install spots. We don't
# hard-fail when it's missing; the agent might be installed in a
# location the user wants us to discover.
CLAUDE_BIN=""
for candidate in \
    "$(command -v claude 2>/dev/null || true)" \
    "$HOME/.claude/local/bin/claude" \
    "/opt/homebrew/bin/claude" \
    "/usr/local/bin/claude"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        CLAUDE_BIN="$candidate"
        break
    fi
done

if [[ -z "$CLAUDE_BIN" ]]; then
    log "WARN: claude binary not found on PATH or in standard locations."
    log "      Falling back to a notification telling the user to repair manually."
    osascript <<EOF >/dev/null 2>&1 || true
display notification "Could not auto-repair: \`claude\` CLI not installed." with title "${TRACKER_NAME:-Tracker} scrape failed" sound name "Funk"
EOF
    exit 2
fi

log "  using claude binary: $CLAUDE_BIN"

# Build the agent prompt. Keep it short, action-oriented, and let the
# agent decide which MCP tools to use. We intentionally do NOT pre-spec
# selector ideas — the agent should inspect the live DOM.
read -r -d '' AUTO_REPAIR_PROMPT <<PROMPT || true
You are repairing a broken tracker in the stats-widget app.

Tracker context:
- Name: ${TRACKER_NAME}
- ID: ${TRACKER_ID}
- URL: ${TRACKER_URL}
- Current (failing) selector: ${TRACKER_SELECTOR}
- Error: ${ERROR_MESSAGE:-unknown}
- Consecutive failure count: ${CONSECUTIVE_FAILURE_COUNT:-?}

Goal: re-identify the correct element on the page and patch the tracker.

Steps:
1. Use the stats-widget MCP server (mcp__stats-widget__* tools) to read the tracker. The socket lives at ${MCP_SOCKET_PATH}. If that MCP isn't connected, also try Chrome DevTools MCP or any HTML-fetching tool to inspect ${TRACKER_URL}.
2. Determine why the existing selector failed. Common causes: the page renamed a class, an A/B test moved the value into a new container, the user signed out and the page now renders a login screen instead of the metric.
3. Pick a new CSS selector that targets the same metric. Prefer stable structural selectors over auto-generated class names.
4. Call mcp__stats-widget__update_tracker (or repair_tracker) with the tracker id ${TRACKER_ID} and the new selector. Verify by calling trigger_scrape and confirming the returned status is 'ok'.
5. After confirming the fix, send a macOS notification with the EXACT title and body below so the user knows the repair landed:
   osascript -e 'display notification "element reidentified by agent" with title "${TRACKER_NAME}" sound name "Glass"'

If you genuinely cannot determine the right selector (page requires interactive sign-in, the metric was removed entirely, etc.), send a different notification explaining what blocked you, and DO NOT change the selector to a wrong one.
PROMPT

# Stage the prompt to a temp file because it's too big to embed inline
# in the AppleScript do-script call.
PROMPT_FILE="$(mktemp -t stats-widget-auto-repair-prompt.XXXXXX)"
printf '%s' "$AUTO_REPAIR_PROMPT" >"$PROMPT_FILE"
log "  prompt staged at $PROMPT_FILE ($(wc -c <"$PROMPT_FILE") bytes)"

# Build the command that the new Terminal window will run. We change
# directory to the user's home so claude finds its global settings
# (~/.claude/...) before consuming the prompt. The prompt is piped
# through cat so AppleScript escaping stays minimal.
TERMINAL_CMD="cd \"$HOME\" && cat \"$PROMPT_FILE\" | \"$CLAUDE_BIN\" 2>&1; echo; echo '[auto-repair finished — Terminal will stay open so you can review the agent output. Close manually when done.]'; exec bash"

log "  launching Terminal.app with auto-repair agent…"

# Trying Terminal.app first. If the user prefers iTerm or another
# emulator they can swap out the script after first launch (it's
# installed to Application Support and is editable).
osascript <<EOF >>"$LOG_FILE" 2>&1
tell application "Terminal"
    activate
    do script "$TERMINAL_CMD"
end tell
EOF

log "  Terminal launched. Auto-repair script returning."
exit 0
