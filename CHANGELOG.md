# Changelog

## 1.0.2 - 2026-08-07

### Fixed

- Fix azure URL bug

## 1.0.1 - 2026-08-05

### Added

- The publish orchestrator of the gg_one tool family, extracted from gg_one: `DoPublish` with version bump, changelog, registry upload, merge, tags and resume, plus `CanPublish`, `DidPublish`, the workspace folder guard and the version tag tools.
- Add the missing example to each new package

### Changed

- Split gg_one into gg_one_core, gg_one_commit, gg_one_merge and gg_one_do_publish
- Port the .gg/gg.json ignore guard from gg_one main into gg_one_core
