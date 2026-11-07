#!/bin/bash
# sync-ai-central.sh — archive this Mac's Claude Code sessions to a central
# shared folder, and share them with other machines through it.
#
#   ./sync-ai-central.sh            # archive: this machine's sessions -> central shared folder (default)
#   ./sync-ai-central.sh restore    # restore: merged sessions central shared folder -> this machine
#
# The central shared folder comes from shared-path.txt next to this script (the "mac:"
# line). Override with:  AI_CENTRAL=/path/to/central ./sync-ai-central.sh
# An optional "machine:" line names this machine's archive folder (default: the
# Mac's LocalHostName).
#
# The central shared folder has two parts:
#
#   merged   projects/ (transcripts) and claude-code-sessions/ (only the
#            local_*.json index entries and deleted_* tombstones), merged from
#            every machine. archive writes these; restore copies them back.
#   archive  machines/<name>/ — everything else worth keeping from this machine
#            (per-machine index state, file history, plans, tasks, side-session
#            notes, Cowork sessions, CLAUDE.md, ...). Written by archive; never restored,
#            since one machine's copy would overwrite the other's.
#
# Credentials and keys never leave this machine. Copies are additive and
# newest-wins (-u): nothing is ever deleted from either side. When an archive
# run replaces a file in the central shared folder, the old copy is kept under
# machines/<name>/versions/<timestamp>/ (transcripts excepted: they only grow).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATHS_FILE="$SCRIPT_DIR/shared-path.txt"

# value of a "key:" line in shared-path.txt; tolerates Windows line endings
read_key() {
    [ -f "$PATHS_FILE" ] || return 0
    tr -d '\r' < "$PATHS_FILE" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1
}

if [ -n "${AI_CENTRAL:-}" ]; then
    CENTRAL="$AI_CENTRAL"
else
    if [ ! -f "$PATHS_FILE" ]; then
        cat >&2 <<'EOF'
shared-path.txt not found next to this script — nothing synced.
Copy shared-path.txt.example to shared-path.txt and fill in the central shared
folder for each OS, e.g.:

  mac: /path/to/ai-central
  windows: \\server\share\path\to\ai-central
EOF
        exit 1
    fi
    CENTRAL="$(read_key mac)"
    if [ -z "$CENTRAL" ]; then
        echo "error: no 'mac:' line found in $PATHS_FILE — nothing synced." >&2
        exit 1
    fi
fi

MODE="${1:-archive}"

CLAUDE_HOME="$HOME/.claude"
APP_DATA="$HOME/Library/Application Support/Claude"
PROJECTS="$CLAUDE_HOME/projects"
SESSIONS="$APP_DATA/claude-code-sessions"
MACHINE="$(read_key machine)"
[ -n "$MACHINE" ] || MACHINE="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
ARCHIVE="$CENTRAL/machines/$MACHINE"
VERSIONS="$ARCHIVE/versions/$(date +%Y-%m-%d_%H%M%S)"

if [ "$MODE" != "archive" ] && [ "$MODE" != "restore" ]; then
    echo "usage: $0 [archive|restore]" >&2
    exit 2
fi

# rsync filters (first match wins). Archive runs also pass --backup-dir, which
# keeps the copy they replace under versions/<timestamp>/<tree>.
# The index tree splits in two: entries and tombstones are merged; everything
# else in it (backlog/, waiting-input/, archived-sessions.idx,
# scheduled-tasks.json, ...) is per-machine state.
INDEX_MERGED=(--include '*/' --include 'local_*.json' --include 'deleted_*' --exclude '*' --prune-empty-dirs)
INDEX_LOCAL=(--exclude 'local_*.json' --exclude 'deleted_*' --prune-empty-dirs)
# never archived, wherever they turn up (Cowork sessions carry their own .claude/)
SECRETS=(--exclude '*.key' --exclude '.audit-key' --exclude '.claude.json*' --exclude '.credentials.json')
# from ~/.claude: what the CLI keeps per session, plus your own instructions
CLAUDE_HOME_KEEP=(--include '/file-history/***' --include '/plans/***' --include '/tasks/***'
                  --include '/skills/***' --include '/agents/***' --include '/commands/***'
                  --include '/output-styles/***' --include '/CLAUDE*.md' --include '/settings.json'
                  --exclude '*')
# from the app's data folder: side-session notes, Cowork sessions (not its
# bundled skills), worktree map and session presets
APP_DATA_KEEP=(--include '/side-session-notes/***'
               --exclude '/local-agent-mode-sessions/skills-plugin/' --include '/local-agent-mode-sessions/***'
               --include '/git-worktrees.json' --include '/ccd-session-presets.json'
               --exclude '*')

# Refuse to run if a central shared folder under /Volumes isn't actually mounted: if
# its parent is on the same device as /Volumes itself, it's a plain local dir
# and writing there would silently fill the boot disk instead of the share.
case "$CENTRAL" in
    /Volumes/*)
        parent="$(dirname "$CENTRAL")"
        if [ ! -d "$parent" ] || [ "$(stat -f %d "$parent")" = "$(stat -f %d /Volumes)" ]; then
            echo "error: $parent is not a mounted volume — connect the share first (Finder: Go > Connect to Server)" >&2
            exit 1
        fi
        ;;
esac
if [ ! -d "$(dirname "$CENTRAL")" ]; then
    echo "error: $(dirname "$CENTRAL") does not exist — nothing synced." >&2
    exit 1
fi

mkdir -p "$CENTRAL/projects" "$CENTRAL/claude-code-sessions"

# rsync -v prints each file it copies, but also every directory it traverses
# (lines ending in "/") and its own header/footer lines — filter to just the
# actual files so the output is real progress, and count them.
sync_tree() {
    local label="$1" src="$2" dst="$3"
    shift 3
    echo ""
    echo "==> $label"
    echo "    $src  ->  $dst"
    mkdir -p "$dst"
    local out files rc=0
    out="$(rsync -auv "$@" "$src/" "$dst/")" || rc=$?
    # 24 = a file vanished mid-copy (the app tidying up); anything else is a real
    # failure and must not be reported as "up to date"
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
        echo "error: rsync failed (exit $rc): $src -> $dst" >&2
        exit 1
    fi
    files="$(echo "$out" \
        | grep -v -e '^$' -e '/$' -e '^\./\{0,1\}$' \
                  -e '^Transfer starting' -e '^sending' -e '^building' \
                  -e '^sent ' -e '^total size' || true)"
    if [ -n "$files" ]; then
        echo "$files" | sed 's/^/    /'
        echo "    -- $(echo "$files" | wc -l | tr -d ' ') file(s) copied"
    else
        echo "    -- up to date, nothing to copy"
    fi
}

if [ "$MODE" = "archive" ]; then
    echo "Archiving merged sessions -> $CENTRAL"
    sync_tree "transcripts (.claude/projects)" "$PROJECTS" "$CENTRAL/projects"
    sync_tree "session index (claude-code-sessions)" "$SESSIONS" "$CENTRAL/claude-code-sessions" \
        --backup "--backup-dir=$VERSIONS/claude-code-sessions" "${INDEX_MERGED[@]}"
    echo ""
    echo "Archiving this machine's own data -> $ARCHIVE"
    sync_tree "per-machine index state" "$SESSIONS" "$ARCHIVE/claude-code-sessions" \
        --backup "--backup-dir=$VERSIONS/machine-claude-code-sessions" "${INDEX_LOCAL[@]}"
    sync_tree "~/.claude (file history, plans, tasks, instructions)" "$CLAUDE_HOME" "$ARCHIVE/dot-claude" \
        --backup "--backup-dir=$VERSIONS/dot-claude" "${SECRETS[@]}" "${CLAUDE_HOME_KEEP[@]}"
    sync_tree "app data (side-session notes, Cowork sessions, worktrees, presets)" "$APP_DATA" "$ARCHIVE/app-data" \
        --backup "--backup-dir=$VERSIONS/app-data" "${SECRETS[@]}" "${APP_DATA_KEEP[@]}"
    if [ -d "$VERSIONS" ]; then
        echo ""
        echo "Replaced files kept in $VERSIONS"
    fi
else
    echo "Restoring merged sessions $CENTRAL -> this machine"
    echo "(quit the Claude app first if it's running — it caches the session list)"
    sync_tree "transcripts (.claude/projects)" "$CENTRAL/projects" "$PROJECTS"
    sync_tree "session index (claude-code-sessions)" "$CENTRAL/claude-code-sessions" "$SESSIONS" "${INDEX_MERGED[@]}"
fi
echo ""

echo "Done. Central shared folder now has:"
echo "  $(find "$CENTRAL/projects" -name '*.jsonl' | wc -l | tr -d ' ') transcripts, $(find "$CENTRAL/claude-code-sessions" -name 'local_*.json' | wc -l | tr -d ' ') index entries"
if [ -d "$CENTRAL/machines" ]; then
    for m in "$CENTRAL/machines"/*/; do
        echo "  machines/$(basename "$m"): $(find "$m" -type f -not -path '*/versions/*' | wc -l | tr -d ' ') archived files"
    done
fi
