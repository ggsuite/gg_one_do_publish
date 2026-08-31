# Changelog

## Unreleased

### Changed

- Use ggwsm in pipelines

### Fixed

- Fix Windows-specific test failures that blocked the review

## 2.6.0 - 2026-08-14

### Changed

- Rework copyright headers

### Fixed

- Cleanup copy right headers. Update to dart 3.13. Auto fixes.
- Cleanup copy right headers. Update to dart 3.13. Auto fixes. Setup quick-check pipeline.

## 2.5.2 - 2026-08-12

### Fixed

- Fix package adding algorithm

## 2.5.1 - 2026-08-11

### Changed

- Provide gg via npm
- Fix shell changes

## 2.5.0 - 2026-08-10

### Changed

- The publish runtime file is split: `.gg/publish_config.json` (answers) and `.gg/publish_state.json` (run state). `--restart` discards only the state
- `publish_config.json` is removed right before the merge, `publish_state.json` on full success
- Refactor commit messages, version increment

## 2.4.3 - 2026-08-10

### Added

- `do publish` upgrades and tightens the dependencies (»dart pub upgrade
--major-versions --tighten«) before validating and releasing — `--no-upgrade`
(or `upgrade: false`) turns it off for callers that upgrade themselves

### Changed

- Make sure »dart pub upgrade --tighten --major-versions« is called before publishing

## 2.4.2 - 2026-08-10

### Fixed

- Various fixes

## 2.4.1 - 2026-08-10

### Removed

- Merge .ticket with ticket.json. Remove usage of .ticket

## 2.4.0 - 2026-08-09

### Changed

- Improve commit behavior
- Answer gg did publish from git tags instead of a marker
- Move the git and process plumbing to gg_git
- Record the doCommit state in system commits again

## 2.3.0 - 2026-08-09

### Changed

- **`do publish` merges into main BEFORE it publishes.** The release order
used to be upload first, merge second — a merge that was then refused left a
version on pub.dev/npm that never reached main, and a registry cannot take an
upload back. Now the `doCommit` and `didPublish` states are recorded
immediately before the merge (the merge itself carries them into the default
branch — in the pull-request flow the provider merges main, and gg cannot
push a fix afterwards), the feature branch is merged into the default branch
(and, without a pull request, main is pushed right away), and only then is
the package uploaded to its registries — from the feature branch, whose
content the merge made identical to main. A refused merge now stops the
release while the registries are untouched; the merged-but-not-yet-uploaded
state resumes with `--continue`.
- After the upload the default branch is checked out to tag the release and
push the tags, then the feature branch is checked out again and the workspace
overrides (`pubspec_overrides.yaml` / `pnpm-workspace.yaml`) are restored
from their `.gg/` backups — the repository keeps resolving against the
sibling checkouts of its ticket workspace, so work simply continues. The
restore re-records `didPublish` for the restored working tree; a merge-only
run restores too but keeps recording nothing.
- A resumed run whose merge already happened no longer pushes the feature
branch at the start — the push had nothing to offer and would resurrect an
already-deleted remote feature branch.
- **The old main state never reaches the worktree.** The merge itself is
checkout-free (see gg_one_merge: plumbing squash on the feature branch, ref
fast-forward after a pull-request merge), the direct main push of the local
flow moves the bare ref (`git push origin <main>`) instead of checking main
out, and the `doPush` state is recorded before the merge — together with
`doCommit`/`didPublish` — so it rides into main inside the squash. The only
checkout of the whole publish is the tag step, and it switches to a main
that already carries the release — content-identical to the feature branch
— never to an old state whose changed files would make editor tooling
descend on the worktree and rewrite lock files mid-release.
- Merge in main before publishing

## 2.2.0 - 2026-08-09

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
