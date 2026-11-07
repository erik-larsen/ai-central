# ai-central

Scripts that keep every Claude Code session (desktop app and CLI, Mac + Windows) safe in one central shared folder: a network share or any other folder every machine can reach. They have two goals, in this order:

1. **Archive.** Everything a session leaves behind on a machine ends up in the central shared folder and is never deleted there, even pieces no other machine can use: transcripts, index entries, file history, plans, task lists, side-session notes, Cowork sessions and the backlog.
2. **Share.** Sessions from every machine show up in the app on every machine.

## Claude session data

A desktop-app session is **two** pieces; both are needed for it to appear and open. A CLI session is just the transcript.

| Piece | Mac | Windows |
|---|---|---|
| Transcript (`<uuid>.jsonl`) | `~/.claude/projects/<encoded-path>/` | `%USERPROFILE%\.claude\projects\<encoded-path>\` |
| Index entry (`local_*.json`) | `<app data>/claude-code-sessions/<account>/<org>/` | `<app data>\claude-code-sessions\<account>\<org>\` |
| *App data folder* (`<app data>`) | `~/Library/Application Support/Claude/` | `%APPDATA%\Claude\` |

The CLI and the app also keep more per-session data around those two pieces (file history, plans, notes, ...). That data is worth archiving, but most of it can't be merged between machines.

Sharing assumes every machine signs in to the same Claude account: the app lists only the sessions filed under the signed-in account's `<account>/<org>/` folder. Sessions from another account are still archived; they just won't show up.

## What goes where

```
ai-central/
├── projects/                  # merged: transcripts from all machines
├── claude-code-sessions/      # merged: index entries and tombstones from all machines
└── machines/<name>/           # archive: one folder per machine, push only
    ├── claude-code-sessions/  #   per-machine files from the index folder
    ├── dot-claude/            #   from ~/.claude
    ├── app-data/              #   from the app data folder
    └── versions/<timestamp>/  #   old copies of files a push replaced
```

`<name>` is the Mac's LocalHostName or the Windows `COMPUTERNAME`, unless `shared-path.txt` sets `machine:`. Set it if you might rename a machine, since a new name starts a new archive folder.

| What | Where it lives locally | Goes to | Notes |
|---|---|---|---|
| Transcripts, subagent logs, memory | `.claude/projects/` | merged | |
| Index entries `local_*.json` | index folder | merged | |
| Tombstones `deleted_<uuid>` | index folder | merged | Mark deleted sessions, so a deletion on one machine sticks on the other. |
| `backlog/`, `waiting-input/`, `archived-sessions.idx`, `scheduled-tasks.json` | index folder | archive | One copy per machine. Merging would replace one machine's copy with the other's. |
| `file-history/` | `.claude/` | archive | Copies of files from before Claude edited them (used by rewind). |
| `plans/`, `tasks/` | `.claude/` | archive | Plan-mode plans and per-session task lists. |
| `CLAUDE*.md`, `settings.json`, and `skills/`, `agents/`, `commands/`, `output-styles/` if present | `.claude/` | archive | Your own instructions and config. |
| `side-session-notes/` | app data | archive | Notes left by linked side sessions. |
| `local-agent-mode-sessions/` | app data | archive | Cowork sessions: index entry, transcript, uploads, outputs. Its bundled `skills-plugin/` is skipped. |
| `git-worktrees.json`, `ccd-session-presets.json` | app data | archive | Which worktree belongs to which session; saved session presets. |

### Never copied

- **Credentials and keys:** `.claude/.claude.json` and its `backups/`, `*.key` files (in `.claude/sessions/` and inside Cowork sessions), `.audit-key`, `.credentials.json`, and the app's `config.json`, which holds the OAuth token cache. Filters for these apply to every archived folder, including the copy of `.claude/` inside each Cowork session.
- **Environment captures,** which can contain secrets: `shell-snapshots/`, `session-env/`.
- **MCP config:** `claude_desktop_config.json`.
- **Things that are reinstallable or useless on their own:** caches, telemetry, app binaries, VM bundles (around 10 GB), and `git-shadow/` (refs into your repos' own object stores, meaningless without the repo).
- **Code in worktrees.** The archive keeps session data, not your work. Commit and push it.

The archive can still hold secrets that ended up in files: an API key in `settings.json`'s `env` block, or a `.env` file Claude edited (its earlier contents land in `file-history/`). Protect the central shared folder accordingly.

## Sync scripts

The scripts read the central shared folder's location from `shared-path.txt` next to them (gitignored — copy `shared-path.txt.example` and fill in your paths).

Mac:

```bash
./sync-ai-central.sh          # push: archive + share this machine's sessions (default)
./sync-ai-central.sh pull     # pull: merged sessions central -> local (quit Claude app first)
```

Windows (PowerShell):

```powershell
.\sync-ai-central.ps1          # push: archive + share this machine's sessions (default)
.\sync-ai-central.ps1 pull     # pull: merged sessions central -> local (quit Claude app first)
```

`push` copies the merged part and this machine's archive folder. `pull` brings back only the merged part; archive folders are never pulled. Run `push` on a machine after working there; run `pull` (with the app fully quit, including the tray icon on Windows) before working somewhere else.

Both are additive and newest-wins: nothing is ever deleted from either side. When a push replaces a file in the central shared folder, the old copy moves to `machines/<name>/versions/<timestamp>/`, so earlier versions of your backlog, `CLAUDE.md`, index entries and so on survive. Transcripts are the exception: they are append-only, so the newer copy already contains the older one.

If any copy fails, the script stops with an error instead of carrying on.

**Cross-machine resume:** every session appears in the list on every machine, but *continuing* one only fully works if its project folder exists at the same absolute path on that machine. A session started in `<your-home>/code/foo` on one machine expects that exact path on the other, and Mac and Windows paths never match. Sessions run in a worktree (`<repo>/.claude/worktrees/<name>`) reference that worktree's path, which is local and usually short-lived, so on the other machine they are effectively read-only. Reading is fine regardless.

**Cleanup pruning:** set `"cleanupPeriodDays": 9999` in `~/.claude/settings.json` / `%USERPROFILE%\.claude\settings.json` on every machine, or startup cleanup deletes old local session data. The central shared folder keeps its copy either way, but a `pull` would then bring old sessions straight back.

## Restoring

Everything in the central shared folder is plain files, so restoring is copying them back with the Claude app quit.

- **Sessions:** `pull` on any machine restores every merged transcript and index entry.
- **A machine's archive:** copy what you need from `machines/<name>/` back to the same place: `dot-claude/` into `~/.claude/`, `app-data/` into the app data folder, `claude-code-sessions/` into the app data folder's `claude-code-sessions/`. Copy into a fresh install, or one file at a time; don't overwrite a working machine's newer files wholesale.
- **An older version of a file:** look in `machines/<name>/versions/<timestamp>/`, which mirrors the tree it came from.
- **Without the app:** transcripts are JSONL, one JSON object per line, so any text editor or `jq` can read them.
