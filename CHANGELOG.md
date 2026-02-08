# Changelog
All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning.

## [Unreleased]
### Added
- Command echo before running `rclone size`.
- Live status line with listed count and elapsed time formatting.
- Optional logging toggle via `RCLONE_SIZE_LOG`.
- Colorized terminal output with log files kept clean.
- Backend-aware fast-list behavior and OneDrive delta support.
- CLI flags: `--fast-list`, `--no-fast-list`, `--help`.
- Pass-through arguments (including `--` mode) to `rclone size`.
- Human-readable total size output from rclone.
- Markdown history log for terminal output after folder selection.
- README with usage and behavior documentation.
