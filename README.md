# Get Cloud Folder Size

Interactive rclone folder size checker with TUI menus. Pick a remote, choose a
top-level folder, and get live progress plus a final size summary. Caches
results for quick re-display.

> **Get Cloud Folder Size** - Version: 1.10  
> Author: Rich Lewis - GitHub: @RichLewis007

## Features

- Interactive menu (fzf/gum with bash fallback).
- Live progress line: `Listed N,NNN` and `Elapsed time`.
- Prints the exact `rclone size` command before running.
- Optional logging to file (disabled by default).
- History log in Markdown for each size run.
- Cache of size results for faster re-display.
- Backend-aware `--fast-list` behavior for Google Drive and OneDrive.
- Pass-through args to `rclone size`.

## Requirements

- `rclone` (required)
- `fzf` or `gum` (optional for interactive TUI menus; falls back to bash `select`)

## Install

1. Ensure `rclone` is installed and configured with remotes.
2. Make the script executable:

```bash
chmod +x get-cloud-folder-size.sh
```

## Usage

```bash
./get-cloud-folder-size.sh
```

### CLI flags

```bash
./get-cloud-folder-size.sh --fast-list
./get-cloud-folder-size.sh --no-fast-list
./get-cloud-folder-size.sh -h
./get-cloud-folder-size.sh -- --tpslimit 10
```

### Environment variables

```bash
LOG_DIR=./log
SIZE_DATA_FILE=./get-cloud-folder-size-data.txt
HISTORY_FILE=./get-cloud-folder-size-history.md
RCLONE_SIZE_LOG=1
RCLONE_SIZE_ARGS="--fast-list"
FAST_LIST_MODE=auto   # auto|on|off
```

## Behavior Notes

- Fast-list policy: `FAST_LIST_MODE=auto` (default) adds `--fast-list` for Google Drive only.
- `--fast-list` forces it on for all remotes.
- `--no-fast-list` disables it and strips it from extra args.
- OneDrive adds `--onedrive-delta` only when fast-list is enabled.
- Logging is disabled by default.
- Enable logging with `RCLONE_SIZE_LOG=1` to save full rclone output.
- Terminal output is colorized; logs never contain color codes.
- Unknown CLI args are forwarded to `rclone size`.
- Use `--` to force pass-through mode: `./get-cloud-folder-size.sh -- --tpslimit 10`.
- The history log records all terminal output after folder selection.

## Output

You will see:

- A `Sizing:` line.
- The exact `rclone size` command as it will be executed.
- A live status line with listed count and elapsed time.
- Final totals including bytes and rclone’s human-readable total size.
- A Markdown history entry in `get-cloud-folder-size-history.md`.

Note on units: rclone’s human-readable sizes may be shown in binary units
(MiB/GiB) while other tools show decimal units (MB/GB). These differ by ~2.4%.
For background, see:
```
https://simple.wikipedia.org/wiki/Mebibyte
https://physics.nist.gov/cuu/Units/binary.html
```

## Files

- `get-cloud-folder-size.sh` — main script
- `get-cloud-folder-size-data.txt` — cache (generated)
- `log/` — optional logs when `RCLONE_SIZE_LOG=1` (generated)
- `get-cloud-folder-size-history.md` — Markdown history log (generated)

## Troubleshooting

- No remotes shown: run `rclone listremotes` to confirm rclone is configured.
- Slow listing: try `--fast-list` (or `--no-fast-list`) to compare.
- No live updates: ensure `stdbuf` exists (optional). The script falls back gracefully if it is not available.

## Changelog

See `CHANGELOG.md`.
