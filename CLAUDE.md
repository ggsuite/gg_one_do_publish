# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`gg_one_do_publish` holds the publish orchestrator of the gg_one tool family: `DoPublish` with version bump, changelog, merge, registry upload, tags and resume, plus `CanPublish`, `DidPublish`, the workspace folder guard and the version tag tools.

The package is part of the gg_one tool family (see the `gg_one` umbrella repo for the family overview). All commands extend `DirCommand<T>` from `gg_args`; the primary logic lives in `get()`, and `exec()` delegates to it. `ggLog` is constructor-injected everywhere for testability.

## Behavior notes

### `--no-pana`

`can publish` and `do publish` both take `--no-pana` (pana runs by default). The
flag is not a parameter of any `exec`/`get` — it travels in the `options` map of
`DirCommand.exec` under the `panaOption` key, which `CommandCluster` hands to
every command it runs. `CanPublish` fills the key in from its own
`--[no-]pana` when the caller left it out, and `do publish` forwards its own
flag as `{panaOption: <value>}` to `can publish`. `Pana` itself takes no
options, so the skip lives in the `OptionalPana` wrapper `CanPublish` puts
around it: with `pana: false` it logs »Skipping pana (--no-pana)« and returns.
That keeps gg_multi's mocked `exec` calls matching — an extra named parameter
would not.

- **`did/`** — historical checks (was something done?): `did_commit`, `did_push`, `did_publish`, `did_upgrade`. `did publish` reads the hash-keyed `didPublish` state `do publish` records — »is what I have here released?« — under a **new** key name, because the legacy `doPublish` key is on `GgState.obsoleteKeys` and would be pruned on the next state write.
  - `do_publish` refuses to run in a **ticket workspace folder** (`tools/workspace_folder_guard.dart`: a directory that is no git repository — no `.git` folder or file — but holds a `ticket.json` or a `<ticket>.code-workspace`). Running it there would operate on a non-repository and fail with confusing git errors; the message points at `gg multi do publish`, which publishes the ticket's repositories in dependency order. The guard runs right after the directory check, before any other step, and has no `--force` escape — the folder is simply not a repository.
  - `do_publish` merges through an auto-merge pull request **by default** (`--pr`, GitHub and Azure DevOps): the PR is created with the merge message as title — or the one `gg_multi do review` already opened is reused, which keeps its review-time title while the merge message still becomes the squash commit message — set to auto-complete with the **squash** strategy (and the message as squash commit message), and the publish waits for the provider merge (`gg_merge`'s `WaitForMerge`, unbounded poll). Afterwards the registry upload runs from the feature branch and only tags are pushed to main. `--no-pr` restores the local merge + direct push to main; providers without PR support (e.g. self-hosted GitLab) fall back to the local merge with a warning. Enabling automerge is best-effort: a policy rejection leaves the PR open with a warning and the publish waits for a manual merge. The flow is resume-safe in two ways: pre-push-hook worktree drift (a »dart run« hook's implicit `pub get` rewriting `pubspec.lock` — gg installs no hooks itself, but a repo may carry one of its own) is committed and re-pushed so the final checkout of main never fails on a dirty tree, and when a resumed run finds all release content already on main (the PR of a crashed run was merged — detected via `git diff --name-only` against `origin/<main>`, ignoring `.gg/` and lock-file drift, because a squash merge defeats ancestry checks) the PR creation and wait are skipped entirely.

### Merge-only mode (`do publish --merge-only`, the only way to merge without releasing — in gg_multi too, where `gg do merge` was removed as well)

`--merge-only` runs the **entire** publish flow with every release artifact left out: the version bump **and** the `CHANGELOG.md` release heading (`prepare_version`), the registry upload (`publish_registry`, plus the `WaitUntilPublished` wait that follows it) and the version tag (`tag`, plus the tag push). Manifest version, CHANGELOG heading and git tag are one unit — bumping the manifest while neither of the other two follows would leave the main branch claiming a version that was never released. The branch therefore keeps its released version plus its `## Unreleased` entries, exactly the state a repo has between releases, and the next real publish releases them. Everything else is unchanged — `can publish`, the ticket-marker removal, the merge (pull request or local), the state bookkeeping, the pushes and the feature-branch deletion all run as usual. None of the skipped steps is recorded in `done_steps`, so a later `gg do publish --continue` never mistakes them for done (a merge-only run records no step at all).

Because a merge-only run puts the branch on the main branch _without_ releasing it, it refuses while `pubspec_overrides.yaml` still redirects a dependency to a local working copy (`NoPubspecOverrides.hasLocalizedRefs`) — such a reference would never become resolvable for anybody else. `--force` merges anyway and then removes the file for the merge and restores it at the end like a normal publish (without re-recording `didPublish`, which a merge-only run never writes). Both are also parameters of `exec`/`get` (`mergeOnly`, `force`), which is how gg_multi's `do publish --merge-only` drives them.

Note that a merge leaves no tag behind, so its work stays _unreleased_ on the main branch. gg_multi's `PublishSkipCheck` therefore compares against the last **tag** rather than the main branch — see the gg_multi CLAUDE.md.

### Publish flow (`do_publish` + `do_configure_publish`)

**The release order is: merge FIRST, upload SECOND.** After the version bump the `doCommit` and `didPublish` states are recorded immediately before the merge (so the merge itself carries them into the default branch — in the pull-request flow the provider merges main and gg cannot push a fix afterwards), the feature branch is merged into the default branch (and, in the local-merge flow, main is pushed right away), and only then is the package uploaded to its registries — **from the feature branch**, whose content the merge made identical to the default branch, so the upload's lock-file bookkeeping never sits on a local main that gg cannot push in the pull-request flow. A merge that is refused (rejected pull request, protected branch, conflict) therefore stops the release while the registries are untouched — the reverse order left versions on pub.dev/npm that never reached main, and a registry cannot take an upload back; the merged-but-not-yet-uploaded state is simply resumed with `--continue`. After the upload (and the registry-visibility wait) the default branch is checked out to tag the release and push the tags, then the feature branch is checked out again and the workspace overrides (`pubspec_overrides.yaml` / `pnpm-workspace.yaml`) are restored from their `.gg/` backups, so work on the ticket can continue — the restore changes the working tree, so `didPublish` is recorded once more for exactly that state.

A `--merge-only` run asks for **no version increment** at all: it releases nothing, so `do configure-publish` skips the prompt (its own `--merge-only` flag does the same) and writes no `version_increment`; `PublishConfig.resolveSingle`/`forRepo` accept a missing one via `requireVersionIncrement: false`.

`do publish` resolves all interactive input **up front** — version increment, merge message AND the delete-feature-branch decision (`delete_feature_branch` in the config; `configure-publish` asks it, `--[no-]delete-feature-branch` presets it, and the resolved value is persisted in the runtime file so a resume never re-asks): explicit parameters (the gg_multi flow) / CLI flags > `--config <path>` > an existing `<repo>/.gg/gg-publish.json` > an automatic interactive `do configure-publish` (which writes that file; `-m` presets the merge message and skips its prompt). No prompt ever sits between the irreversible publish steps. Every default prompt is guarded by `throwWhenNotATerminal` (`tools/terminal_guard.dart`): without a TTY it fails fast with an actionable message instead of hanging (CI, pipes). While the publish runs, per-step progress is recorded in the same `.gg/gg-publish.json` (`done_steps`: `prepare_version`, `publish_registry_pub_dev`, `publish_registry_npm`, `merge`, `tag` — the three pushes and the feature-branch deletion are idempotent and always re-run; the deletion looks the remote ref up via `git ls-remote --heads origin <branch>` first and silently skips a branch that is already gone — e.g. deleted by the provider on a pull-request merge). After the registry steps, `do publish` waits until the version is actually **visible** on pub.dev/npm (gg_publish's `WaitUntilPublished`): it announces the wait including a status URL, logs progress and fails with a bounded timeout instead of hanging; the wait is idempotent (returns immediately once visible) and therefore always re-runs on resume. The file also records the feature `branch`, because a resumed run may find HEAD on the default branch already — but the persisted branch is only trusted **when resuming**; a leftover config-only file (a run that failed in `can publish`) must never pin a stale branch that a later publish would then delete. On full success the file is deleted.

Resume semantics: a leftover file with `done_steps` makes a plain `do publish` **refuse** (resume with `--continue`, discard with `--restart`) — unless the recorded `branch` is a _different feature branch_ than HEAD's: then the progress is a stale leftover of another publish that arrived with a copy of the repository (the file is gitignored, so copying a workspace carries it along) and is **discarded automatically** with a warning (a `--continue` refuses instead, with the same explanation), because trusting it would skip the current publish's version bump and registry upload and could delete the wrong feature branch; a mismatch while HEAD is on the default branch is _not_ stale — a resumed run whose merge already happened legitimately sits there; `--continue` (or the programmatic `resume: true` that `gg_multi do publish --continue` forwards) skips the done steps and skips `can publish` (the checks would fail on a half-published repo) — but it runs the hash-keyed `did commit` check, which survives gg's own bookkeeping commits and fails exactly when raw commits were added after the failure, so nothing unvalidated is ever published on a resume. When the merge step is already done, the feature-branch push at the start is skipped entirely — it has nothing new to offer and would resurrect the possibly already-deleted remote feature branch; the remaining steps check their own branches out themselves (the default branch for the main push and the tag, the persisted feature branch for the registry upload and the restore). `do configure-publish` refuses to overwrite a file that carries `done_steps` (that would silently discard the resume state). `EnsurePublishConfigIgnored` (in `tools/`) guarantees the publish runtime files — `.gg/gg-publish.json` and the `pubspec_overrides.yaml` backup at `.gg/pubspec_overrides_backup.yaml` — are gitignored before they are first written (appending + committing the `.gitignore` change with a `GgState.updateHash` transplant so recorded check results stay valid); it first runs `EnsureGgJsonNotIgnored`, so a repository that git-ignored the whole `.gg/` folder is healed instead of crashing the `git add` of the bootstrap commit. Two GgState keys are written immediately **before** the merge: `doCommit` (so a later `gg did commit` — CI, or a repo's own hook — accepts the release commit) and `didPublish` (read back by `gg did publish`; **not** written in merge-only mode, which releases nothing — and recorded once more at the end, when the restored workspace overrides changed the working tree). The merge itself carries both into the default branch — `GgState` hashes the tree and ignores `.gg/`, and a squash merge keeps the tree, so the hashes recorded on the feature branch are exactly the hashes of the default branch after the merge. Both are written with **`ignoreUnstaged: true`**, as are the `doCommit`/`doPush` states `MergeFlow` records before the pull request: they describe the *committed* release content, while `GgState` otherwise hashes untracked files too. A publish runs build, test and packaging scripts, and `_commitPendingChanges` deliberately commits only tracked files (`git add --update`) — so an artifact one of them drops for a moment would be hashed into the state without ever being committed, and every later `gg did commit` would report »Not committed yet« the instant that file is gone again. The read side still hashes the full working tree, so real uncommitted work keeps failing the check. The former `doPublish`/`doMerge` keys are gone — the _step_ resume relies solely on `done_steps` in the git-ignored `.gg/gg-publish.json`, and `GgState` prunes the legacy keys (`doPrepareVersion`, `doPublishPubDev`, `doMerge`, `doPublishGit`, `doPublish`) from the tracked `.gg/gg.json` whenever it writes a state. The main-branch push goes through `DoPush.get` (not raw `gitPush`), which records the `doPush` state on the release commit before pushing — otherwise `gg did push` fails on every CI checkout of a freshly published package. The final tag push stays a raw `gitPush(pushTags: true)`, because `DoPush.get` neither pushes tags nor pushes at all once everything is up to date.

All commands extend `DirCommand<T>` from `gg_args`. The primary logic lives in `get()`, and `exec()` simply delegates to it. `ggLog` (a `GgLog` function alias) is constructor-injected everywhere for testability and output capture.

## Testing Conventions

- 100% code coverage is required. Exempt lines with `// coverage:ignore-line` or `// coverage:ignore-start` / `// coverage:ignore-end`.
- Each implementation file must have a corresponding `_test.dart` in the mirrored path under `test/`.
- Mock classes are defined at the bottom of the **same file** as the class they mock, using `mocktail` and extending `MockDirCommand<T>`.
- Tests use `gg_git_test_helpers` (including the cached repo helpers) and `gg_capture_print`.

### Hybrid packages

A repository carrying both a `pubspec.yaml` and a `package.json` publishes to
pub.dev **and** npm, and each manifest decides for its own side (gg_lang's
`publishTargetsOf`). Three things follow:

- **The registry step is tracked per registry** (`publish_registry_pub_dev`,
  `publish_registry_npm`). The marker is written *between* the two uploads, so a
  run whose pub.dev upload succeeded before npm failed resumes at npm alone. A
  registry that already carries the version is marked done without uploading —
  the second safety net. A leftover single `publish_registry` marker from an
  older gg is announced and **re-checked per registry** rather than translated:
  it cannot say which registry it reached, so "both done" would permanently skip
  pub.dev and "neither" would re-upload to npm.
- **The two manifests are reconciled to the higher version** right before
  `can publish`, and the result is committed with a `GgState.updateHash`
  transplant. When they differed, pana is turned off for that run with a
  warning — the reconciled version has no `CHANGELOG.md` section yet, which pana
  rejects, and the alternative is an abort the user can only resolve by hand.
  `gg_multi`'s per-repo gate runs *before* gg_one's publish and reaches the same
  conclusion itself via `hybridVersionsDiffer`.
- **A hybrid that publishes to pub.dev uses the Dart CHANGELOG flow** and the
  Dart version tag, because pub.dev shows the CHANGELOG on the package page and
  pana scores it. An npm-only hybrid keeps the TypeScript flow. Every
  non-hybrid is unchanged — `_supportsChangeLog` only consults the publish
  target for a hybrid, so a `publish_to: none` Dart package keeps its CHANGELOG
  flow. One tag covers both registries, and tagging refuses when the manifests
  still disagree.
