# Changelog

## Unreleased

### Changed

- `do publish` uploads a hybrid to **both** of its registries and records a
`done_steps` marker per registry (`publish_registry_pub_dev`,
`publish_registry_npm`). A run whose pub.dev upload succeeded before npm failed
resumes at npm alone — the marker is written between the two uploads, so the
successful one is on disk before the next can fail. A registry that already
carries the version is marked done without uploading, which is the second
safety net.
- A leftover single `publish_registry` marker from an older gg is announced and
**re-checked per registry** instead of trusted. It cannot say which registry it
reached: treating it as "both done" would permanently skip pub.dev for a
hybrid, treating it as "neither" would re-upload to npm.
- Right before `can publish`, the two manifests of a hybrid are reconciled to
the **higher** version and the result is committed. Nothing kept them together
before, so they drifted, and publishing released two different versions of one
artifact. When they differed, pana is skipped for that run with a warning — the
reconciled version has no CHANGELOG.md section yet, which pana rejects, and the
alternative is an abort the user can only resolve by hand.
- A hybrid that publishes to pub.dev now uses the Dart CHANGELOG.md flow and
the Dart version tag: pub.dev shows the CHANGELOG on the package page and pana
scores it. An npm-only hybrid keeps the TypeScript flow. Every non-hybrid is
unchanged — a `publish_to: none` Dart package keeps its CHANGELOG flow.
- Tagging refuses when the two manifests still disagree. One tag has to cover
both registries, so a manual edit that broke the lock-step would otherwise
mislabel one side.
- The lock-file commit covers **both** ecosystems of a hybrid.
- Allow to publish hybrid packages

## 2.1.0 - 2026-08-08

### Added

- `--no-pana` for `can publish` and `do publish`: skips the pana analysis. It
travels through the `options` map of `DirCommand.exec` (`panaOption`).

## 2.0.0 - 2026-08-08

### Changed

- Allow to pass custom options to exec of dir commands.

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
