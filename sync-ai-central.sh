#!/bin/bash
# sync-ai-central.sh — archive this Mac's Claude Code sessions to a central
# shared folder, and share them with other machines through it.
#
#   ./sync-ai-central.sh archive /path/to/ai-central   # this machine's sessions -> central shared folder
#   ./sync-ai-central.sh restore /path/to/ai-central   # merged sessions central shared folder -> this machine
#
# Options:
#   --machine NAME   name of this machine's archive folder under machines/
#                    (default: the Mac's LocalHostName)
#
# The central shared folder has two parts:
#
#   merged   projects/ (transcripts) and claude-code-sessions/ (only the
#            local_*.json index entries and deleted_* tombstones), merged from
#            every machine. archive writes these; restore copies them back.
#   archive  machines/<name>/ — everything else worth keeping from this machine
#            (per-machine index state, file history, plans, tasks, side-session
#            notes, Cowork sessions, CLAUDE.md, ...). Written by archive; never
#            restored, since one machine's copy would overwrite the other's.
#
# Credentials and keys never leave this machine. Copies are additive and
# newest-wins (-u): nothing is ever deleted from either side. When an archive
# run replaces a file in the central shared folder, the old copy is kept under
# machines/<name>/versions/<timestamp>/ (transcripts excepted: they only grow).

set -euo pipefail

usage() {
    echo "usage: $0 archive|restore <central shared folder> [--machine NAME]" >&2
    exit 2
}

MODE="" CENTRAL="" MACHINE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --machine) [ $# -ge 2 ] || usage; MACHINE="$2"; shift 2 ;;
        -*) usage ;;
        *)
            if [ -z "$MODE" ]; then MODE="$1"
            elif [ -z "$CENTRAL" ]; then CENTRAL="${1%/}"
            else usage
            fi
            shift ;;
    esac
done
if [ "$MODE" != "archive" ] && [ "$MODE" != "restore" ]; then usage; fi
[ -n "$CENTRAL" ] || usage

CLAUDE_HOME="$HOME/.claude"
APP_DATA="$HOME/Library/Application Support/Claude"
PROJECTS="$CLAUDE_HOME/projects"
SESSIONS="$APP_DATA/claude-code-sessions"
[ -n "$MACHINE" ] || MACHINE="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
ARCHIVE="$CENTRAL/machines/$MACHINE"
VERSIONS="$ARCHIVE/versions/$(date +%Y-%m-%d_%H%M%S)"

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
# (lines ending in "/") and its own header/footer lines — show just the actual
# files as they're copied, numbered, and count them.
sync_tree() {
    local label="$1" src="$2" dst="$3"
    shift 3
    echo ""
    echo "==> $label"
    echo "    $src  ->  $dst"
    mkdir -p "$dst"
    local line count=0 rc=0 start=$SECONDS
    while IFS= read -r line; do
        case "$line" in
            '__rsync_exit '*) rc="${line#__rsync_exit }" ;;
            ''|*/|.|'Transfer starting'*|sending*|building*|'sent '*|'total size'*) ;;
            *) count=$((count + 1)); echo "    [$count] $line" ;;
        esac
    done < <(rsync -auv "$@" "$src/" "$dst/" || echo "__rsync_exit $?")
    # 24 = a file vanished mid-copy (the app tidying up); anything else is a real
    # failure and must not be reported as "up to date"
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
        echo "error: rsync failed (exit $rc): $src -> $dst" >&2
        exit 1
    fi
    if [ "$count" -gt 0 ]; then
        echo "    -- $count file(s) copied in $((SECONDS - start))s"
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
