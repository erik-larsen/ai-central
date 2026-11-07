# sync-ai-central.ps1 -- archive this PC's Claude Code sessions to a central
# shared folder, and share them with other machines through it.
#
#   .\sync-ai-central.ps1              # archive: this machine's sessions -> central shared folder (default)
#   .\sync-ai-central.ps1 restore      # restore: merged sessions central shared folder -> this machine
#   .\sync-ai-central.ps1 archive -Central \\server\share\path\to\ai-central
#
# The central shared folder comes from shared-path.txt next to this script (the
# "windows:" line); the -Central parameter overrides it. An optional "machine:"
# line names this machine's archive folder (default: COMPUTERNAME).
#
# The central shared folder has two parts:
#
#   merged   projects\ (transcripts) and claude-code-sessions\ (only the
#            local_*.json index entries and deleted_* tombstones), merged from
#            every machine. archive writes these; restore copies them back.
#   archive  machines\<name>\ -- everything else worth keeping from this machine
#            (per-machine index state, file history, plans, tasks, side-session
#            notes, Cowork sessions, CLAUDE.md, ...). Written by archive; never restored,
#            since one machine's copy would overwrite the other's.
#
# Credentials and keys never leave this machine. Copies are additive and
# newest-wins (/XO): nothing is ever deleted from either side. When an archive
# run replaces a file in the central shared folder, the old copy is kept under
# machines\<name>\versions\<timestamp>\ (transcripts excepted: they only grow).

param(
    [ValidateSet('archive', 'restore')]
    [string]$Mode = 'archive',
    [string]$Central
)

$ErrorActionPreference = 'Stop'

$pathsFile = Join-Path $PSScriptRoot 'shared-path.txt'

# value of a "key:" line in shared-path.txt, or $null
function Read-Key($key) {
    if (-not (Test-Path $pathsFile)) { return $null }
    $line = Get-Content $pathsFile | Where-Object { $_ -match "^\s*${key}:" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -replace "^\s*${key}:\s*", '').Trim()
}

if (-not $Central) {
    if (-not (Test-Path $pathsFile)) {
        Write-Host 'shared-path.txt not found next to this script - nothing synced.'
        Write-Host 'Copy shared-path.txt.example to shared-path.txt and fill in the central shared'
        Write-Host 'folder for each OS, e.g.:'
        Write-Host ''
        Write-Host '  mac: /path/to/ai-central'
        Write-Host '  windows: \\server\share\path\to\ai-central'
        exit 1
    }
    $Central = Read-Key 'windows'
    if (-not $Central) {
        Write-Host "error: no 'windows:' line found in $pathsFile - nothing synced."
        exit 1
    }
}

$machine = Read-Key 'machine'
if (-not $machine) { $machine = $env:COMPUTERNAME }

$claudeHome = Join-Path $env:USERPROFILE '.claude'
$appData = Join-Path $env:APPDATA 'Claude'
$projects = Join-Path $claudeHome 'projects'
$sessions = Join-Path $appData 'claude-code-sessions'
$archive = Join-Path $Central "machines\$machine"
$versions = Join-Path $archive "versions\$(Get-Date -Format 'yyyy-MM-dd_HHmmss')"

if (-not (Test-Path (Split-Path $Central -Parent))) {
    throw "Cannot reach $(Split-Path $Central -Parent) - is the share online and accessible?"
}

New-Item -ItemType Directory -Force -Path "$Central\projects", "$Central\claude-code-sessions" | Out-Null

# The index tree splits in two: entries and tombstones are merged; everything
# else in it (backlog\, waiting-input\, archived-sessions.idx,
# scheduled-tasks.json, ...) is per-machine state.
$indexMerged = @('local_*.json', 'deleted_*')
# never archived, wherever they turn up (Cowork sessions carry their own .claude\)
$secrets = @('/XF', '*.key', '.audit-key', '.claude.json*', '.credentials.json')

# $files are robocopy file patterns (default: all); $opts are extra switches.
# With $keepAs, files about to be replaced in $dst are first copied to
# $versions\$keepAs (robocopy has no backup option of its own).
function Sync-Tree($label, $src, $dst, [string[]]$files = @(), [string[]]$opts = @(), $keepAs = $null) {
    if (-not (Test-Path $src)) { Write-Host "skip (missing): $src"; return }
    Write-Host ""
    Write-Host "==> $label"
    Write-Host "    $src  ->  $dst"
    # /S all non-empty subdirs, /XO skip older (newest wins), /FFT tolerant
    # timestamps for SMB.
    $common = @('/S', '/XO', '/FFT', '/R:2', '/W:2')
    if ($keepAs -and (Test-Path $dst)) {
        # /L lists what would be copied, as full source paths (/FP), one per line
        $pending = robocopy $src $dst @files @common /L /NJH /NJS /NDL /NC /NS /FP /NP @opts
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE): $src -> $dst" }
        $srcRoot = (Resolve-Path $src).Path.TrimEnd('\')
        foreach ($p in $pending) {
            $p = $p.Trim()
            if (-not $p.StartsWith($srcRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = $p.Substring($srcRoot.Length).TrimStart('\')
            $old = Join-Path $dst $rel
            if (Test-Path -LiteralPath $old -PathType Leaf) {
                $kept = Join-Path (Join-Path $versions $keepAs) $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $kept -Parent) | Out-Null
                Copy-Item -LiteralPath $old -Destination $kept
            }
        }
    }
    # Per-file lines print as files copy; the job summary (/NJS removed) shows
    # totals for Copied / Skipped / Bytes for each tree.
    robocopy $src $dst @files @common /NP /NDL /NJH @opts
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE): $src -> $dst" }
}

if ($Mode -eq 'archive') {
    Write-Host "Archiving merged sessions -> $Central"
    Sync-Tree 'transcripts (.claude\projects)' $projects "$Central\projects"
    Sync-Tree 'session index (claude-code-sessions)' $sessions "$Central\claude-code-sessions" $indexMerged @() 'claude-code-sessions'

    Write-Host ""
    Write-Host "Archiving this machine's own data -> $archive"
    Sync-Tree 'per-machine index state' $sessions "$archive\claude-code-sessions" @() (@('/XF') + $indexMerged) 'machine-claude-code-sessions'
    # from .claude: what the CLI keeps per session, plus your own instructions
    foreach ($d in 'file-history', 'plans', 'tasks', 'skills', 'agents', 'commands', 'output-styles') {
        Sync-Tree ".claude\$d" "$claudeHome\$d" "$archive\dot-claude\$d" @() $secrets "dot-claude\$d"
    }
    Sync-Tree '.claude instructions + settings' $claudeHome "$archive\dot-claude" @('CLAUDE*.md', 'settings.json') @('/LEV:1') 'dot-claude'
    # from the app's data folder: side-session notes, Cowork sessions (not its
    # bundled skills), worktree map and session presets
    Sync-Tree 'side-session notes' "$appData\side-session-notes" "$archive\app-data\side-session-notes" @() $secrets 'app-data\side-session-notes'
    Sync-Tree 'Cowork sessions' "$appData\local-agent-mode-sessions" "$archive\app-data\local-agent-mode-sessions" @() (@('/XD', 'skills-plugin') + $secrets) 'app-data\local-agent-mode-sessions'
    Sync-Tree 'worktree map + session presets' $appData "$archive\app-data" @('git-worktrees.json', 'ccd-session-presets.json') @('/LEV:1') 'app-data'
    if (Test-Path $versions) {
        Write-Host ""
        Write-Host "Replaced files kept in $versions"
    }
} else {
    Write-Host "Restoring merged sessions $Central -> this machine"
    Write-Host "(quit Claude for Windows first, including the system tray icon)"
    Sync-Tree 'transcripts (.claude\projects)' "$Central\projects" $projects
    Sync-Tree 'session index (claude-code-sessions)' "$Central\claude-code-sessions" $sessions $indexMerged
}

$t = (Get-ChildItem "$Central\projects" -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue).Count
$i = (Get-ChildItem "$Central\claude-code-sessions" -Recurse -Filter local_*.json -ErrorAction SilentlyContinue).Count
Write-Host "Done. Central shared folder now has: $t transcripts, $i index entries"
foreach ($m in Get-ChildItem "$Central\machines" -Directory -ErrorAction SilentlyContinue) {
    $n = (Get-ChildItem $m.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike '*\versions\*' }).Count
    Write-Host "  machines\$($m.Name): $n archived files"
}
