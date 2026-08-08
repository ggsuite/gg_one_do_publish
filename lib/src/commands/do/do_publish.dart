// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';
import 'dart:convert';
import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_changelog/gg_changelog.dart' as changelog;
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_merge/gg_merge.dart' as gg_merge;
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_one_do_publish/src/commands/can/can_publish.dart';
import 'package:gg_one_do_publish/src/tools/add_git_only_version_tag.dart';
import 'package:gg_one_do_publish/src/tools/add_typescript_version_tag.dart';
import 'package:gg_one_do_publish/src/tools/workspace_folder_guard.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_version/gg_version.dart';
import 'package:path/path.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:gg_one_commit/gg_one_commit.dart';
import 'package:gg_one_merge/gg_one_merge.dart';

/// Publishes the current directory.
///
/// All interactive decisions (version increment, merge message, feature
/// branch deletion) are resolved up front — from explicit parameters,
/// `--config`, an existing `.gg/gg-publish.json` or an automatic
/// `do configure-publish` — so no prompt ever sits between the irreversible
/// publish steps. While the publish runs, its per-step progress is recorded
/// in `<repo>/.gg/gg-publish.json` (see [allowedPublishSteps]); a failed
/// run can be resumed with `--continue` and skips the steps already done.
/// The file is deleted after a fully successful publish.
///
/// With `--merge-only` the very same flow runs, minus every step that would
/// release the package: the version is not increased, no `CHANGELOG.md`
/// release heading is written, nothing is uploaded to a package registry and
/// no version tag is created — and no version increment is asked for either.
/// It brings a ticket onto the main branch without releasing it: the branch
/// keeps the released version and its »## Unreleased« entries, and the next
/// real publish releases them. Because the merged state is never resolvable
/// against a registry, it is refused while
/// [NoPubspecOverrides.hasLocalizedRefs] reports localized references —
/// `--force` overrides that.
/// Flags, in more detail than their one-line help texts carry:
/// - `--no-pr` performs a local merge instead of merging through an
///   auto-merge pull request and waiting for the provider.
/// - `--message` skips the interactive merge-message prompt.
/// - `--config` is resolved as given (relative to the CWD), then below the
///   repository.
/// - `--channel rc` publishes the next `X.Y.Z-rc.N` prerelease of the target
///   version instead of the stable release.
/// - `--continue` reuses `.gg/gg-publish.json` and skips the steps that are
///   already done; `--restart` discards config *and* progress.
class DoPublish extends DirCommand<void> {
  /// Constructor
  DoPublish({
    required super.ggLog,
    super.name = 'publish',
    super.description = 'Publish this repo',
    CanPublish? canPublish,
    Publish? publish,
    GgState? state,
    AddVersionTag? addVersionTag,
    AddTypeScriptVersionTag? addTypeScriptVersionTag,
    AddGitOnlyVersionTag? addGitOnlyVersionTag,
    RemoveVersionTag? removeVersionTag,
    Commit? commit,
    DoPush? doPush,
    DidCommit? didCommit,
    PrepareNextVersion? prepareNextVersion,
    FromPubspec? fromPubspec,
    IsPublished? isPublished,
    changelog.Release? release,
    changelog.HasVersion? hasVersion,
    PublishTo? publishTo,
    MergeFlow? mergeFlow,
    PublishedVersion? publishedVersion,
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
    LocalBranch? localBranch,
    ConfirmDeleteFeatureBranch? confirmDeleteFeatureBranch,
    DoConfigurePublish? configurePublish,
    EnsurePublishConfigIgnored? ensureIgnored,
    WaitUntilPublished? waitUntilPublished,
    // coverage:ignore-start
  }) : _canPublish = canPublish ?? CanPublish(ggLog: ggLog),
       _publishToPubDev = publish ?? Publish(ggLog: ggLog),
       _state = state ?? GgState(ggLog: ggLog),
       _addVersionTag = addVersionTag ?? AddVersionTag(ggLog: ggLog),
       _addTypeScriptVersionTag =
           addTypeScriptVersionTag ??
           AddTypeScriptVersionTag(
             ggLog: (msg) => ggLog('✓ $msg'),
             processWrapper: processWrapper,
           ),
       _addGitOnlyVersionTag =
           addGitOnlyVersionTag ??
           AddGitOnlyVersionTag(
             ggLog: (msg) => ggLog('✓ $msg'),
             processWrapper: processWrapper,
           ),
       // Like _addVersionTag: operates on the real repo, not through the
       // command's own process wrapper.
       _removeVersionTag = removeVersionTag ?? RemoveVersionTag(ggLog: ggLog),
       _commit = commit ?? Commit(ggLog: ggLog),
       _doPush = doPush ?? DoPush(ggLog: ggLog),
       _didCommit = didCommit ?? DidCommit(ggLog: ggLog),
       _prepareNextVersion =
           prepareNextVersion ?? PrepareNextVersion(ggLog: ggLog),
       _fromPubspec = fromPubspec ?? FromPubspec(ggLog: ggLog),
       _releaseChangelog = release ?? changelog.Release(ggLog: ggLog),
       _hasVersion = hasVersion ?? changelog.HasVersion(ggLog: ggLog),
       _isPublished = isPublished ?? IsPublished(ggLog: ggLog),
       _publishTo = publishTo ?? PublishTo(ggLog: ggLog),
       _mergeFlow = mergeFlow ?? MergeFlow(ggLog: ggLog),
       _publishedVersion = publishedVersion,
       _processWrapper = processWrapper,
       _localBranch = localBranch ?? LocalBranch(ggLog: ggLog),
       _confirmDeleteFeatureBranch =
           confirmDeleteFeatureBranch ??
           DoConfigurePublish.defaultConfirmDeleteFeatureBranch,
       _configurePublish = configurePublish ?? DoConfigurePublish(ggLog: ggLog),
       _ensureIgnored =
           ensureIgnored ?? EnsurePublishConfigIgnored(ggLog: ggLog),
       _waitUntilPublished =
           waitUntilPublished ?? WaitUntilPublished(ggLog: ggLog) {
    // coverage:ignore-end
    _addArgs();
  }

  /// The key used to save the "all changes committed" state (read back by
  /// »gg did commit«, e.g. in CI).
  final String stateKeyDoCommit = 'doCommit';

  /// The key used to save the "this state is published" state (read back by
  /// »gg did publish« and by the multi-repo flow, which uses it to tell
  /// released repos from ones that still carry unpublished work).
  final String stateKeyDidPublish = 'didPublish';

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? askBeforePublishing,
    String? message,
    bool? deleteFeatureBranch,
    bool? verbose,
    String? versionIncrement,
    String? channel,
    bool? resume,
    bool? pr,
    bool? mergeOnly,
    bool? force,
    Map<String, dynamic> options = const {},
  }) => get(
    directory: directory,
    ggLog: ggLog,
    askBeforePublishing: askBeforePublishing,
    message: message,
    deleteFeatureBranch: deleteFeatureBranch,
    verbose: verbose,
    versionIncrement: versionIncrement,
    channel: channel,
    resume: resume,
    pr: pr,
    mergeOnly: mergeOnly,
    force: force,
    pana: options[panaOption] as bool?,
  );

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? askBeforePublishing,
    String? message,
    bool? deleteFeatureBranch,
    bool? verbose,
    String? versionIncrement,
    String? channel,
    bool? resume,
    bool? pr,
    bool? mergeOnly,
    bool? force,
    bool? pana,
  }) async {
    final isVerbose = verbose ?? _verboseFromArgs;
    final usePana = pana ?? _panaFromArgs;
    final isMergeOnly = mergeOnly ?? _mergeOnlyFromArgs;
    final isForce = force ?? _forceFromArgs;
    _publishedVersion ??= PublishedVersion(ggLog: ggLog);

    // Does directory exist?
    await check(directory: directory);
    void noLog(_) {} // coverage:ignore-line

    // A ticket folder is no repository — publishing it would fail somewhere
    // deep inside git. Point at »gg multi do publish« right away instead.
    throwWhenInWorkspaceFolder(directory);

    // Never publish a repo whose registry target is currently suppressed by
    // the ticket tooling (»gg multi do add« writes »publish_to: none« and
    // backs the original value up). Without this guard the publish silently
    // skips the upload and merges the suppressed manifest into main.
    _throwIfPublishTargetIsSuppressed(directory);

    final cliContinue = argResults?['continue'] as bool? ?? false;
    final restart = argResults?['restart'] as bool? ?? false;
    final configArg = argResults?['config'] as String?;
    message ??= _messageFromArgs;

    if (cliContinue && (configArg != null || restart)) {
      throw Exception(cError(continueConflictMessage));
    }

    // Step 0b: A pubspec_overrides.yaml redirects dependencies to local
    // working copies and must not be in effect while publishing. Delete it
    // before anything else — before »can publish« checks for it, and before
    // the first bookkeeping commit could carry it into the release.
    //
    // A merge-only run refuses instead of just deleting: it puts the branch on
    // the main branch WITHOUT releasing it, so a dependency that only exists
    // as a local working copy would never become resolvable for anybody else.
    // »--force« says the user knows and wants it merged regardless — then the
    // file is deleted like in a normal publish.
    if (isMergeOnly && !isForce) {
      _throwIfRefsAreLocalized(directory);
    }
    _deletePubspecOverrides(directory: directory, ggLog: ggLog);

    // Step 1: Read the runtime .gg/gg-publish.json (config + progress).
    final runtimeFile = DoConfigurePublish.configFileFor(directory);
    if (cliContinue && !runtimeFile.existsSync()) {
      throw Exception(
        cError(
          'Nothing to continue: ${runtimeFile.path} does not exist. Start a '
          'normal "gg do publish" first.',
        ),
      );
    }
    if (restart && runtimeFile.existsSync()) {
      // Explicit user choice: discard the previous config and progress.
      runtimeFile.deleteSync();
    }
    PublishConfig? runtimeConfig = runtimeFile.existsSync()
        ? PublishConfig.load(
            configArg: runtimeFile.path,
            fallbackDir: directory.path,
          )
        : null;

    // Step 1b: Progress that was recorded on a DIFFERENT feature branch does
    // not belong to this publish — it is a leftover that arrived with a copy
    // of the repository (the file is gitignored, so copying a workspace
    // carries it along, e.g. »gg multi do add« copying the ocean
    // into a new ticket). Trusting it would skip this publish's version bump
    // and registry upload and could delete the wrong feature branch — so
    // discard it. Progress found while HEAD is on the default branch is
    // kept: a resumed run whose merge already happened legitimately sits
    // there.
    if (runtimeConfig != null && runtimeConfig.hasStepProgress) {
      final staleBranch = runtimeConfig.branch;
      final currentBranch = await _localBranch.get(
        directory: directory,
        ggLog: <String>[].add,
      );
      final onDefaultBranch =
          currentBranch == 'main' || currentBranch == 'master';
      if (staleBranch != null &&
          staleBranch != currentBranch &&
          !onDefaultBranch) {
        runtimeFile.deleteSync();
        runtimeConfig = null;
        final notice =
            'The progress in ${runtimeFile.path} belongs to the branch '
            '"$staleBranch", but the current branch is "$currentBranch". '
            'The file is a stale leftover of another publish and was '
            'discarded.';
        if (cliContinue) {
          throw Exception(
            cError(
              '$notice There is nothing to continue — start a fresh '
              '"gg do publish".',
            ),
          );
        }
        ggLog(cDetail(notice));
      }
    }

    // A resumed run continues at the first step that is not done yet.
    // gg_multi forwards its own --continue via [resume].
    final resuming =
        (cliContinue || (resume ?? false)) &&
        (runtimeConfig?.hasStepProgress ?? false);

    if (!resuming && (runtimeConfig?.hasStepProgress ?? false)) {
      throw Exception(
        cError(
          unfinishedPublishMessage(
            path: runtimeFile.path,
            command: 'gg do publish',
          ),
        ),
      );
    }

    // Step 3: Make the runtime file invisible to git before it is written.
    await _ensureIgnored.ensure(directory: directory);

    // Step 4: Resolve version increment, merge message and the
    // delete-feature-branch decision. Precedence: explicit parameters (the
    // gg_multi flow) / CLI flags > --config > the runtime
    // .gg/gg-publish.json > an interactive `do configure-publish`. Every
    // interactive decision happens HERE — never between the irreversible
    // publish steps.
    String? resolvedIncrement = versionIncrement;
    String? resolvedMessage = message;
    String? resolvedChannel = channel ?? _channelFromArgs;
    bool? resolvedDelete = deleteFeatureBranch;
    if (resolvedDelete == null && _deleteFeatureBranchWasProvided) {
      resolvedDelete = _deleteFeatureBranchFromArgs;
    }
    bool? resolvedPr = pr;
    if (resolvedPr == null && _prWasProvided) {
      resolvedPr = _prFromArgs;
    }
    // A merge-only run creates no release, so it needs no version increment —
    // neither from a config file nor from a prompt.
    final needsIncrement = !isMergeOnly;
    if ((needsIncrement && resolvedIncrement == null) ||
        resolvedMessage == null) {
      if (configArg != null) {
        final config = PublishConfig.load(
          configArg: configArg,
          fallbackDir: join(directory.path, '.gg'),
        );
        final resolved = config.resolveSingle(
          configPath: configArg,
          requireVersionIncrement: needsIncrement,
        );
        resolvedIncrement ??= resolved.versionIncrement;
        resolvedMessage ??= resolved.mergeMessage;
        resolvedChannel ??= config.channel;
        resolvedDelete ??= config.deleteFeatureBranch;
        resolvedPr ??= config.pr;
      } else if (runtimeConfig != null) {
        final resolved = runtimeConfig.resolveSingle(
          configPath: runtimeFile.path,
          requireVersionIncrement: needsIncrement,
        );
        resolvedIncrement ??= resolved.versionIncrement;
        resolvedMessage ??= resolved.mergeMessage;
        resolvedChannel ??= runtimeConfig.channel;
        resolvedDelete ??= runtimeConfig.deleteFeatureBranch;
        resolvedPr ??= runtimeConfig.pr;
      } else {
        final config = await _configurePublish.configure(
          directory: directory,
          ggLog: ggLog,
          versionIncrement: resolvedIncrement,
          mergeMessage: resolvedMessage,
          deleteFeatureBranch: resolvedDelete,
          mergeOnly: isMergeOnly,
        );
        resolvedIncrement = config.versionIncrement;
        resolvedMessage = config.mergeMessage;
        resolvedChannel ??= config.channel;
        resolvedDelete ??= config.deleteFeatureBranch;
      }
    } else {
      // Increment + message came as parameters, only the channel, delete and
      // pr decisions may be open — read them from the config file when one is
      // present.
      resolvedChannel ??= runtimeConfig?.channel;
      resolvedDelete ??= runtimeConfig?.deleteFeatureBranch;
      resolvedPr ??= runtimeConfig?.pr;
    }
    resolvedChannel ??= 'stable';
    resolvedPr ??= true;
    _explicitVersionIncrement = resolvedIncrement;
    _explicitChannel = resolvedChannel;

    // The feature branch is persisted in the runtime file: a resumed run may
    // find HEAD on the default branch already (the merge happened), so it
    // must not be re-read from HEAD then. Only a RESUMED run may trust the
    // persisted value — a leftover file from a run that failed before its
    // first step (e.g. in canPublish) must not pin a stale branch that a
    // later publish of a different branch would then delete.
    final featureBranch =
        (resuming ? runtimeConfig?.branch : null) ??
        await _localBranch.get(directory: directory, ggLog: <String>[].add);

    // A config source that predates the delete_feature_branch field (or an
    // explicit --config without it) leaves the decision open — ask NOW,
    // before anything irreversible runs. In non-interactive environments the
    // default prompt fails fast instead of hanging.
    resolvedDelete ??= _confirmDeleteFeatureBranch(featureBranch);

    // Step 5: Persist the resolved config (+ carried-over progress) as the
    // runtime file — the resume anchor for this run. The delete decision is
    // stored too, so a resumed run never has to re-ask.
    var progress = PublishConfig(
      versionIncrement: resolvedIncrement,
      mergeMessage: resolvedMessage,
      channel: resolvedChannel,
      deleteFeatureBranch: resolvedDelete,
      pr: resolvedPr,
      branch: featureBranch,
      doneSteps: resuming ? runtimeConfig!.doneSteps : null,
    );
    await progress.save(file: runtimeFile);

    Future<void> markStepDone(String step) async {
      progress = progress.withStepDone(step);
      await progress.save(file: runtimeFile);
    }

    // Step 6: Validate. The full `can publish` is skipped when resuming —
    // after a partial publish (version bumped, possibly merged) its checks
    // would fail although the remaining steps are perfectly resumable. But
    // commits added AFTER the failed run must not be published unvalidated:
    // »did commit« is hash-keyed and survives gg's own bookkeeping commits,
    // so it fails exactly when raw new commits sneaked in.
    if (resuming) {
      ggLog(
        cDetail('Resuming the unfinished publish — "can publish" is skipped.'),
      );
      final didCommit = await _didCommit.get(
        directory: directory,
        ggLog: <String>[].add,
      );
      if (!didCommit) {
        throw Exception(
          cError(
            'The repository changed since the failed publish. Run '
            '"gg do commit" first, then resume with '
            '"gg do publish --continue".',
          ),
        );
      }
    } else {
      await _canPublish.exec(
        directory: directory,
        ggLog: ggLog,
        options: <String, dynamic>{panaOption: usePana},
      );
    }

    // The final merge goes through an auto-merge pull request by default
    // (--pr): the PR is created with automerge, the publish waits until the
    // provider merged it, then continues. --no-pr restores the local merge
    // followed by a direct push to main. Providers without PR support
    // (anything but GitHub/Azure DevOps) fall back to the local merge with a
    // warning.
    final viaPullRequest =
        resolvedPr && await _pullRequestFlowSupported(directory);

    // A resumed run whose merge already happened may still sit on the
    // feature branch (gg_multi checks it out again after a failure). Move to
    // the default branch BEFORE the first push, so no push resurrects the
    // possibly already-deleted remote feature branch and push/tag target the
    // release commit.
    if (resuming && progress.isStepDone('merge') && !viaPullRequest) {
      await _checkoutDefaultBranch(directory);
    }

    // Drop the ticket marker (written by `gg do add`) BEFORE version bump and
    // registry upload — the upload happens before the merge, so the
    // merge-time removal alone would ship `.gg/ticket.json` to pub.dev/npm
    // inside the published package. Idempotent, so resumes are safe.
    await _mergeFlow.removeTicketJson(
      directory: directory,
      ggLog: ggLog,
      verbose: isVerbose,
    );

    await _doPush.gitPush(directory: directory, force: false);

    // A merge-only run stops short of every release artifact. Announced once,
    // because a run that ends without a release looks like a failed publish
    // otherwise.
    if (isMergeOnly) {
      ggLog(
        darkGray(
          'Merge only: not increasing the version, not releasing the '
          'changelog, not publishing to a package registry and not tagging '
          'the release.',
        ),
      );
    }

    // Step 7: Prepare version + changelog. Skipped by a merge-only run: the
    // version number, the CHANGELOG.md release heading and the git tag are
    // one unit, so bumping the manifest while neither of the other two
    // follows would leave the main branch claiming a version that was never
    // released. The main branch keeps the released version plus its
    // »## Unreleased« entries, and the next real publish releases them.
    if (!isMergeOnly && !progress.isStepDone('prepare_version')) {
      await _prepareVersion(directory: directory, ggLog: ggLog, noLog: noLog);
      await markStepDone('prepare_version');
    }

    // Step 8: Publish to the registry (pub.dev/npm). The registry lookup is
    // a safety net: a version that is already visible must not be published
    // again on a resumed run whose marker got lost. Packages without a
    // registry target (`publish_to: none`, projects without a manifest)
    // skip the whole step — there is no registry version to compare or
    // lock file to update.
    //
    // A merge-only run never uploads anything, so the step (and the wait for
    // registry visibility that follows it) is skipped entirely. No step is
    // marked as done either — the markers would let a later `gg do publish
    // --continue` believe the release already happened.
    if (!isMergeOnly && !progress.isStepDone('publish_registry')) {
      if (await _shouldPublishToRegistry(directory, ggLog)) {
        final alreadyPublished = await _versionAlreadyPublished(
          directory: directory,
          ggLog: ggLog,
        );

        if (!alreadyPublished) {
          final hashBeforePubDev = await _state.currentHash(
            directory: directory,
            ggLog: ggLog,
          );

          await _publishToPubDevIfNeeded(
            directory: directory,
            ggLog: ggLog,
            askBeforePublishing: askBeforePublishing,
          );

          await _commitLockFileIfChanged(
            directory: directory,
            ggLog: ggLog,
            hashBefore: hashBeforePubDev,
            verbose: isVerbose,
          );
        }
      } else {
        // Skipping the registry must never be silent — a publish that ends
        // without an upload looks successful otherwise.
        final target = await _publishTo.fromDirectory(directory);
        ggLog(
          cDetail(
            'Not publishing to a registry: the manifest says '
            '"$target". Only the version bump, merge and tag run.',
          ),
        );
      }
      await markStepDone('publish_registry');
    }

    // Step 8b: Registries take a while to make a fresh upload visible. Wait
    // until the version appears on pub.dev/npm — announced with a status
    // url, reporting progress and bounded by a timeout instead of hanging.
    // Idempotent (returns immediately once the version is visible), so it
    // also runs on resumed runs; packages that publish to no registry are
    // skipped inside. Nothing was uploaded in a merge-only run, so there is
    // nothing to wait for.
    if (!isMergeOnly) {
      await _waitUntilPublished.get(directory: directory, ggLog: ggLog);
    }

    // Step 9: Merge into the default branch. (When the step is already done
    // on a resumed run, the default branch was checked out before Step 6.)
    if (!progress.isStepDone('merge')) {
      await _merge(
        directory: directory,
        message: resolvedMessage,
        verbose: isVerbose,
        viaPullRequest: viaPullRequest,
        deleteSourceBranch: resolvedDelete,
      );
      await markStepDone('merge');
    }

    // The merge/version commits produced a fully-committed, gg-verified HEAD on
    // the main branch. Record it as »doCommit« too, so a later »gg did commit«
    // accepts the merge commit instead of rejecting it.
    await _state.writeSuccess(directory: directory, key: stateKeyDoCommit);

    // Record the merged state as published, so »gg did publish« answers yes
    // for exactly this content. A merge-only run records nothing — it
    // releases nothing, so marking it published would be a lie.
    if (!isMergeOnly) {
      await _state.writeSuccess(directory: directory, key: stateKeyDidPublish);
    }

    // In the pull-request flow the provider already updated main when it
    // merged the PR, so skip the direct main push there.
    if (!viaPullRequest) {
      // Push through DoPush.get, not raw gitPush: it writes the »doPush«
      // success state into .gg/gg.json (amended into the release commit)
      // before pushing, so »gg did push« passes on a fresh CI checkout of
      // main. The doPush state carried over from the feature branch belongs
      // to an older hash and would make CI red on every released package.
      await _doPush.get(directory: directory, force: false, ggLog: noLog);
    }

    // Step 10: Delete the feature branch. The decision was resolved up
    // front (Step 4). Idempotent instead of tracked: a resumed multi-flow
    // run re-pushes the branch before delegating here, so the deletion
    // must re-run — and deleting an already-gone remote ref (e.g. removed
    // by the provider after a pull-request merge) is tolerated inside
    // _deleteFeatureBranch.
    if (resolvedDelete) {
      await _deleteFeatureBranch(
        directory: directory,
        branchName: featureBranch,
        verbose: isVerbose,
      );
    }

    // Step 11: Tag the release and push the tags. A merge-only run marks no
    // release, so it creates no tag — and has none to push.
    if (!isMergeOnly) {
      if (!progress.isStepDone('tag')) {
        await _publishGit(directory: directory, ggLog: ggLog);
        await markStepDone('tag');
      }
      await _doPush.gitPush(directory: directory, force: false, pushTags: true);
    }

    // Step 12: Fully published — the runtime file has served its purpose.
    if (runtimeFile.existsSync()) {
      runtimeFile.deleteSync();
    }
  }

  final Publish _publishToPubDev;
  final CanPublish _canPublish;
  final GgState _state;
  final AddVersionTag _addVersionTag;
  final AddTypeScriptVersionTag _addTypeScriptVersionTag;
  final AddGitOnlyVersionTag _addGitOnlyVersionTag;
  final RemoveVersionTag _removeVersionTag;
  final DoPush _doPush;
  final Commit _commit;
  final DidCommit _didCommit;
  final PrepareNextVersion _prepareNextVersion;
  final FromPubspec _fromPubspec;
  final changelog.Release _releaseChangelog;
  final changelog.HasVersion _hasVersion;
  final IsPublished _isPublished;
  final PublishTo _publishTo;
  final MergeFlow _mergeFlow;
  PublishedVersion? _publishedVersion;
  final GgProcessWrapper _processWrapper;
  final LocalBranch _localBranch;
  final ConfirmDeleteFeatureBranch _confirmDeleteFeatureBranch;
  final DoConfigurePublish _configurePublish;
  final EnsurePublishConfigIgnored _ensureIgnored;
  final WaitUntilPublished _waitUntilPublished;

  /// Pre-resolved version increment; always set before the steps run.
  String? _explicitVersionIncrement;

  /// Pre-resolved release channel; always set before the steps run.
  String? _explicitChannel;

  /// The file »gg multi do add« writes when it replaces a repo's publish
  /// target with »none« for the duration of a ticket.
  ///
  /// A checkout made before the files inside `.gg` were unhidden still carries
  /// the dot-prefixed name. The guard below has to see it too — otherwise a
  /// standalone publish of such a ticket repo would silently release the
  /// suppressed manifest.
  static File publishToBackupFile(Directory directory) {
    const name = 'gg_localize_refs_publish_to_backup.json';
    final file = File(join(directory.path, '.gg', name));
    if (file.existsSync()) {
      return file;
    }

    final legacy = File(join(directory.path, '.gg', '.$name'));
    return legacy.existsSync() ? legacy : file;
  }

  /// Throws when the manifest's publish target was replaced by the ticket
  /// tooling. `gg multi do add` sets `publish_to: none` in every ticket repo
  /// and remembers the original value; `gg multi do publish` restores it
  /// before publishing. A standalone `gg do publish` does not — it would
  /// skip the registry upload and merge the suppressed `publish_to: none`
  /// into the main branch, breaking the released package.
  void _throwIfPublishTargetIsSuppressed(Directory directory) {
    final backup = publishToBackupFile(directory);
    if (!backup.existsSync()) {
      return;
    }

    final Map<String, dynamic> content;
    try {
      content = jsonDecode(backup.readAsStringSync()) as Map<String, dynamic>;
      // coverage:ignore-start
    } catch (_) {
      // An unreadable backup must not block a publish.
      return;
      // coverage:ignore-end
    }

    // The backed-up value is what the package publishes to outside the
    // ticket; »null« means the default (pub.dev). Only a genuinely private
    // package has »none« there — that one may be published as-is.
    final original = content['publish_to_original'] as String?;
    if (original == 'none') {
      return;
    }

    throw Exception(
      cError(
        'This repository is part of a ticket workspace: its publish target is '
        'temporarily set to "none" (${backup.path}). Publishing it directly '
        'would skip the registry upload and merge "publish_to: none" into the '
        'main branch. Publish the ticket with "gg multi do publish" instead, '
        'which restores the publish target first.',
      ),
    );
  }

  /// Returns true when the current version is already visible on the
  /// registry, i.e. publishing it again is obsolete.
  Future<bool> _versionAlreadyPublished({
    required Directory directory,
    required GgLog ggLog,
  }) async {
    final currentVersion = await _fromPubspec.get(
      directory: directory,
      ggLog: <String>[].add,
    );
    try {
      // Prereleases never become the registry's "latest" version, so they
      // must be looked up in the full version list instead.
      if (currentVersion.preRelease.isNotEmpty) {
        final allVersions = await _publishedVersion!.allVersions(
          directory: directory,
          ggLog: <String>[].add,
        );
        return allVersions.contains(currentVersion);
      }

      final publishedVersion = await _publishedVersion!.get(
        directory: directory,
        ggLog: <String>[].add,
      );

      return currentVersion == publishedVersion;
      // coverage:ignore-start
    } catch (e) {
      ggLog(cError('$e'));
      ggLog(cDetail('Package probably not published on pub.dev'));

      return false;
    }
    // coverage:ignore-end
  }

  /// Prepare the next version and release the changelog.
  Future<void> _prepareVersion({
    required Directory directory,
    required GgLog ggLog,
    required GgLog noLog,
  }) async {
    await _addNextVersion(directory, ggLog);

    // CHANGELOG.md release is Dart/Flutter only; TS uses manifest versioning.
    if (_supportsChangeLog(directory)) {
      await _prepareChangelog(
        directory: directory,
        ggLog: noLog,
        reportLog: ggLog,
      );
    }
  }

  /// Publishes to the package registry. Only called from the
  /// `publish_registry` step after `_shouldPublishToRegistry` returned true —
  /// registry-less targets are announced and skipped there.
  Future<void> _publishToPubDevIfNeeded({
    required Directory directory,
    required GgLog ggLog,
    required bool? askBeforePublishing,
  }) async {
    final shouldAskBeforePublishing = await _shouldAskBeforePublishing(
      directory,
      ggLog,
      askBeforePublishing,
    );

    await _publishToPubDev.exec(
      directory: directory,
      ggLog: ggLog,
      askBeforePublishing: shouldAskBeforePublishing,
    );
  }

  /// Performs the merge. With [viaPullRequest] this merges through an
  /// auto-merge pull request and waits until it is merged; otherwise it does
  /// a local merge into main. [deleteSourceBranch] lets the provider delete
  /// the feature branch when it completes the pull request.
  ///
  /// The merge logs stay visible in non-verbose mode too: the pull-request
  /// flow can block for minutes (provider CI + automerge), and without the
  /// »Waiting for pull request to be merged« progress messages the publish
  /// looks like it is hanging.
  Future<void> _merge({
    required Directory directory,
    required String? message,
    required bool verbose,
    required bool viaPullRequest,
    required bool deleteSourceBranch,
  }) async {
    if (viaPullRequest) {
      ggLog(
        darkGray(
          'Merging into the default branch via auto-merge pull request…',
        ),
      );
    }

    await _mergeFlow.get(
      directory: directory,
      ggLog: ggLog,
      automerge: false,
      local: !viaPullRequest,
      message: message,
      verbose: verbose,
      viaPullRequest: viaPullRequest,
      deleteSourceBranch: deleteSourceBranch,
    );
  }

  /// Returns whether the pull-request flow is possible: the git provider of
  /// `origin` must support it (GitHub or Azure DevOps). A missing remote or
  /// an unsupported provider (e.g. a self-hosted GitLab) falls back to the
  /// local merge with a warning instead of failing the publish.
  Future<bool> _pullRequestFlowSupported(Directory directory) async {
    final url = await gg_merge.readOriginUrl(
      directory: directory,
      processWrapper: _processWrapper,
    );
    if (url == null) {
      ggLog(
        cWarn(
          'No remote "origin" found — falling back to a local merge '
          'instead of a pull request.',
        ),
      );
      return false;
    }
    if (gg_merge.providerFromRemoteUrl(url) == null) {
      ggLog(
        cWarn(
          'The git provider of "$url" does not support the pull-request '
          'flow — falling back to a local merge.',
        ),
      );
      return false;
    }
    return true;
  }

  /// Checks out the default branch (`main`/`master`). Used when a resumed run
  /// skips the already-done merge step: the release commit to push and tag
  /// lives on the default branch, not on the feature branch HEAD may be on.
  Future<void> _checkoutDefaultBranch(Directory directory) async {
    final current = await _localBranch.get(
      directory: directory,
      ggLog: <String>[].add,
    );
    for (final candidate in ['main', 'master']) {
      final exists = await _processWrapper.run('git', [
        'rev-parse',
        '--verify',
        '--quiet',
        'refs/heads/$candidate',
      ], workingDirectory: directory.path);
      if (exists.exitCode != 0) {
        continue;
      }
      if (current != candidate) {
        final checkout = await _processWrapper.run('git', [
          'checkout',
          candidate,
        ], workingDirectory: directory.path);
        if (checkout.exitCode != 0) {
          throw Exception(
            cError('git checkout $candidate failed: ${checkout.stderr}'),
          );
        }
        ggLog(cDetail('Checked out $candidate to finish the resumed publish.'));
      }
      return;
    }
  }

  /// Adds the version tag for [directory] so `do_push --tags` carries it.
  /// Dart uses `AddVersionTag` (pubspec ↔ CHANGELOG); TS reads
  /// `package.json` via [AddTypeScriptVersionTag] — required for `#semver:`.
  ///
  /// A tag left behind by a publish that failed after tagging is removed first
  /// (locally and on the remote): it points at a commit this run replaced, so
  /// re-adding it would either be refused (`must be greater ...`) or leave the
  /// release tagged on an abandoned commit. Only a tag that was really removed
  /// is reported — the normal publish must not log a line for a tag that was
  /// never there.
  Future<void> _publishGit({
    required Directory directory,
    required GgLog ggLog,
  }) async {
    final removeMessages = <String>[];
    final tagRemoved = await _removeVersionTag.get(
      directory: directory,
      ggLog: removeMessages.add,
    );
    if (tagRemoved) {
      for (final message in removeMessages) {
        ggLog('✓ $message');
      }
    }

    if (_supportsChangeLog(directory)) {
      await _addVersionTag.exec(
        directory: directory,
        ggLog: (msg) => ggLog('✓ $msg'),
      );
      return;
    }
    final type = checkProjectType(directory);
    if (type == ProjectType.typescript) {
      // Bridges tag from package.json too (published as TypeScript).
      // ggLog with `✓` prefix is bound at construction time.
      await _addTypeScriptVersionTag.exec(directory: directory);
      return;
    }
    if (type == ProjectType.none) {
      // No manifest: the version lives in git tags only. The increment and
      // channel are always resolved before the steps run and survive a
      // resume via the runtime .gg/gg-publish.json.
      await _addGitOnlyVersionTag.exec(
        directory: directory,
        increment: parseVersionIncrement(_explicitVersionIncrement!),
        channel: parseReleaseChannel(_explicitChannel!),
      );
    }
  }

  /// Prepare the changelog for release and commit the result.
  ///
  /// [ggLog] receives the step's own chatter (silenced by the caller),
  /// [reportLog] the messages the user has to see.
  Future<void> _prepareChangelog({
    required Directory directory,
    required GgLog ggLog,
    required GgLog reportLog,
  }) async {
    final hashBefore = await _state.currentHash(
      directory: directory,
      ggLog: ggLog,
    );

    await _releaseChangelog.exec(directory: directory, ggLog: ggLog);

    await _state.updateHash(hash: hashBefore, directory: directory);

    try {
      await _commit.commit(
        ggLog: ggLog,
        directory: directory,
        doStage: true,
        message: '#gg: Prepare changelog for release',
        ammendWhenNotPushed: true,
      );
    } on Exception catch (e) {
      // The changelog release is a no-op once the version already has a
      // section in CHANGELOG.md — a run that bumped the version and released
      // the changelog but died before the registry upload reaches exactly
      // that state. Tolerate the empty commit like [_addNextVersion] does,
      // otherwise the repair run cannot get past the step that is already
      // done and the package is never published.
      if (e.toString().contains('Nothing to commit')) {
        reportLog('The changelog is already released — nothing to commit.');
      } else {
        rethrow;
      }
    }
  }

  /// Increases the version according to the selected increment.
  Future<void> _addNextVersion(Directory directory, GgLog ggLog) async {
    if (!_shouldIncreaseVersion) {
      return;
    }

    // Without a manifest there is no file to bump — the next version is
    // created as a git tag in the tag step instead.
    if (checkProjectType(directory) == ProjectType.none) {
      ggLog(
        'Git-only project — the next version is created as a git tag '
        'in the tag step.',
      );
      return;
    }

    final hashBefore = await _state.currentHash(
      directory: directory,
      ggLog: ggLog,
    );

    final currentVersion = await _currentVersionForIncrementSelection(
      directory: directory,
      ggLog: ggLog,
    );

    // The increment and channel are always resolved before the steps run
    // (parameters, --config, runtime file or `do configure-publish`).
    final increment = parseVersionIncrement(_explicitVersionIncrement!);
    final releaseChannel = parseReleaseChannel(_explicitChannel!);

    // A git merge can carry the next version's section into CHANGELOG.md
    // before it is released (gg sets »CHANGELOG.md merge=union«). Publishing
    // over such a section would silently swallow the »## Unreleased« entries.
    // Refuse right after the registry was asked, before anything is written.
    if (_supportsChangeLog(directory)) {
      await _throwIfNextVersionIsAlreadyInChangelog(
        directory: directory,
        ggLog: ggLog,
        increment: increment,
        channel: releaseChannel,
        publishedVersion: currentVersion,
      );
    }

    await _prepareNextVersion.exec(
      directory: directory,
      ggLog: ggLog,
      increment: increment,
      channel: releaseChannel,
      publishedVersion: currentVersion,
    );

    await _state.updateHash(hash: hashBefore, directory: directory);

    final newVersion = await _fromPubspec.fromDirectory(directory: directory);

    try {
      await _commit.commit(
        ggLog: ggLog,
        directory: directory,
        doStage: true,
        message: '#gg: Finish development of version $newVersion',
        ammendWhenNotPushed: false,
      );
    } on Exception catch (e) {
      // When resuming after a failed publish, the version is already bumped
      // and committed, so there is nothing left to commit. Tolerate the empty
      // commit instead of crashing — this keeps »do publish« idempotent.
      if (e.toString().contains('Nothing to commit')) {
        ggLog('Version $newVersion is already prepared — nothing to commit.');
      } else {
        rethrow;
      }
    }
  }

  /// Throws when the version about to be published already has a section in
  /// CHANGELOG.md and continuing would cause harm.
  ///
  /// Harm means: the »## Unreleased« section still contains entries that the
  /// skipped changelog release would silently swallow, or the version in
  /// pubspec.yaml does not match the version about to be published. A fully
  /// prepared state — pubspec.yaml carries the next version and no unreleased
  /// entries exist — passes silently, so »--restart« and runs that lost their
  /// »./.gg/gg-publish.json« can resume a failed publish.
  Future<void> _throwIfNextVersionIsAlreadyInChangelog({
    required Directory directory,
    required GgLog ggLog,
    required VersionIncrement increment,
    required ReleaseChannel channel,
    required Version publishedVersion,
  }) async {
    final next = await _prepareNextVersion.nextVersion(
      directory: directory,
      ggLog: <String>[].add,
      increment: increment,
      channel: channel,
      publishedVersion: publishedVersion,
    );

    final isInChangelog = await _hasVersion.get(
      directory: directory,
      ggLog: <String>[].add,
      version: next,
    );
    if (!isInChangelog) {
      return;
    }

    final unreleasedHasEntries = await _hasVersion.unreleasedHasEntries(
      directory: directory,
      ggLog: <String>[].add,
    );
    final pubspecVersion = await _fromPubspec.fromDirectory(
      directory: directory,
    );
    if (!unreleasedHasEntries && pubspecVersion == next) {
      return;
    }

    ggLog(
      cError(
        'The next version »$next« is already in ${cPath('./CHANGELOG.md')} '
        '— probably a git merge carried it in.',
      ),
    );
    if (unreleasedHasEntries) {
      ggLog(
        cError(
          'Publishing now would lose the entries still sitting in '
          '»## Unreleased«.',
        ),
      );
    }
    if (pubspecVersion != next) {
      ggLog(
        cError(
          'Additionally the version in ${cPath('./pubspec.yaml')} '
          '(»$pubspecVersion«) does not match »$next«.',
        ),
      );
    }
    ggLog(
      cAction(
        'Please fix ${cPath('./CHANGELOG.md')}: move the »## Unreleased« '
        'entries into the »## $next« section or remove the premature '
        '»## $next« section. Then run ${cCmd('gg do publish')} again.',
      ),
    );

    throw Exception(
      cError('CHANGELOG.md already contains the version »$next«.'),
    );
  }

  /// Resolve the version used as baseline for selecting the next increment.
  Future<Version> _currentVersionForIncrementSelection({
    required Directory directory,
    required GgLog ggLog,
  }) async {
    final publishedVersion = await _publishedVersion!.get(
      ggLog: ggLog,
      directory: directory,
    );

    if (publishedVersion != Version(0, 0, 0)) {
      return publishedVersion;
    }

    return _fromPubspec.fromDirectory(directory: directory);
  }

  /// Returns whether publishing confirmation should be shown.
  Future<bool> _shouldAskBeforePublishing(
    Directory directory,
    GgLog ggLog,
    bool? askBeforePublishing,
  ) async {
    askBeforePublishing ??= _askBeforePublishingFromParam;

    final target = await _publishTo.fromDirectory(directory);
    final publishToNone = target == 'none';
    if (publishToNone) {
      return false;
    }

    final wasPublishedBefore = await _isPublished.get(
      directory: directory,
      ggLog: ggLog,
    );

    if (askBeforePublishing) {
      return true;
    }

    if (wasPublishedBefore) {
      return false;
    }

    throw Exception(
      cError(
        'The package was never published to pub.dev before. '
        'Please call »gg do push« with »--ask-before-publishing« '
        'when publishing the first time.',
      ),
    );
  }

  /// Commits the lock file if it was modified during publishing.
  /// Lock file name is resolved per project type via the language catalog.
  Future<void> _commitLockFileIfChanged({
    required Directory directory,
    required GgLog ggLog,
    required int hashBefore,
    required bool verbose,
  }) async {
    final lockFile = lockFileFor(directory);
    final result = await _runProcess(
      'git',
      ['status', '--porcelain', lockFile],
      directory: directory,
      ggLog: ggLog,
      verbose: verbose,
    );

    if (result.stdout.toString().trim().isEmpty) {
      return;
    }

    await _state.updateHash(hash: hashBefore, directory: directory);

    await _commit.commit(
      ggLog: ggLog,
      directory: directory,
      doStage: true,
      message: '#gg: Update $lockFile',
      ammendWhenNotPushed: true,
    );
  }

  /// Returns whether the package should be published to its registry
  /// (pub.dev for Dart/Flutter, npm for TypeScript). Uses the language-aware
  /// publish target instead of assuming a pubspec.yaml.
  Future<bool> _shouldPublishToRegistry(
    Directory directory,
    GgLog ggLog,
  ) async {
    final target = await _publishTo.fromDirectory(directory);
    return target == 'pub.dev' || target == 'npm';
  }

  /// Whether [directory] uses the Dart/Flutter CHANGELOG.md based versioning
  /// flow. TypeScript and other project types use a registry/manifest flow.
  bool _supportsChangeLog(Directory directory) =>
      checkProjectType(directory).isDartFamily;

  /// Deletes the provided feature branch on the remote. Idempotent: the
  /// remote ref is looked up first, so a branch that is already gone (a
  /// resumed run, or a pull-request merge that deleted the source branch)
  /// is silently skipped instead of producing a misleading warning.
  Future<void> _deleteFeatureBranch({
    required Directory directory,
    required String branchName,
    required bool verbose,
  }) async {
    if (!await _remoteBranchExists(
      directory: directory,
      branchName: branchName,
      verbose: verbose,
    )) {
      return;
    }

    final result = await _runProcess(
      'git',
      <String>['push', 'origin', '--delete', branchName],
      directory: directory,
      ggLog: ggLog,
      verbose: verbose,
    );

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString();
      if (stderr.contains('remote ref does not exist')) {
        ggLog(
          cDetail('Remote feature branch $branchName was already deleted.'),
        );
        return;
      }
      throw Exception(
        cError('git push origin --delete $branchName failed: $stderr'),
      );
    }

    ggLog(cDetail('✓ Deleted remote feature branch $branchName.'));
  }

  /// Throws when [directory] still redirects dependencies to local working
  /// copies. A merge-only run does not release the package, so such a
  /// reference would never become resolvable for anyone but the developer who
  /// merged it — the main branch would carry a package nobody can build.
  void _throwIfRefsAreLocalized(Directory directory) {
    if (!NoPubspecOverrides.hasLocalizedRefs(directory)) {
      return;
    }

    throw Exception(
      cError(
        [
          'Project depends on other local projects. ',
          'Just merging is not possible.',
          '  - Either run ${cCmd('gg do publish')} ',
          '  - Or publish anyway adding ${cCmd('--force')} option.',
        ].join(('\n')),
      ),
    );
  }

  /// Deletes a `pubspec_overrides.yaml` left over from local development, so
  /// the package is published against the versions on pub.dev instead of the
  /// developer's working copies. Does nothing when there is none.
  ///
  /// The file is saved to [pubspecOverridesBackupPath] first: the multi-repo
  /// flow restores it once the merge into the main branch is through, so the
  /// repository keeps resolving against its sibling checkouts after the
  /// publish.
  void _deletePubspecOverrides({
    required Directory directory,
    required GgLog ggLog,
  }) {
    final file = File(join(directory.path, NoPubspecOverrides.fileName));
    if (!file.existsSync()) {
      return;
    }

    backupPubspecOverrides(directory);
    file.deleteSync();
    ggLog(
      cDetail(
        'Saved ${NoPubspecOverrides.fileName} to '
        '$pubspecOverridesBackupPath and deleted it.',
      ),
    );
  }

  /// Returns whether [branchName] still exists on the remote. A failing
  /// lookup (no network, no remote) is treated as »exists« so the actual
  /// delete decides and reports the real error.
  Future<bool> _remoteBranchExists({
    required Directory directory,
    required String branchName,
    required bool verbose,
  }) async {
    final result = await _runProcess(
      'git',
      <String>['ls-remote', '--heads', 'origin', branchName],
      directory: directory,
      ggLog: ggLog,
      verbose: verbose,
    );

    if (result.exitCode != 0) {
      return true;
    }

    return result.stdout.toString().trim().isNotEmpty;
  }

  /// Wrapper around `_processWrapper.run` that prints the command in verbose
  /// mode.
  Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    required Directory directory,
    required GgLog ggLog,
    required bool verbose,
  }) {
    if (verbose) {
      ggLog('\$ $executable ${arguments.join(' ')}');
    }
    return _processWrapper.run(
      executable,
      arguments,
      workingDirectory: directory.path,
    );
  }

  bool get _verboseFromArgs => argResults?['verbose'] as bool? ?? false;

  bool get _askBeforePublishingFromParam =>
      argResults?['ask-before-publishing'] as bool? ?? true;

  bool get _shouldIncreaseVersion =>
      argResults?['increase-version'] as bool? ?? true;

  bool get _deleteFeatureBranchFromArgs =>
      argResults?['delete-feature-branch'] as bool? ?? false;

  bool get _deleteFeatureBranchWasProvided =>
      argResults?.wasParsed('delete-feature-branch') ?? false;

  bool get _prFromArgs => argResults?['pr'] as bool? ?? true;

  bool get _mergeOnlyFromArgs => argResults?['merge-only'] as bool? ?? false;

  bool get _forceFromArgs => argResults?['force'] as bool? ?? false;

  bool get _panaFromArgs => argResults?[panaOption] as bool? ?? true;

  bool get _prWasProvided => argResults?.wasParsed('pr') ?? false;

  String? get _messageFromArgs => argResults?['message'] as String?;

  String? get _channelFromArgs => argResults?['channel'] as String?;

  void _addArgs() {
    argParser.addFlag(
      'ask-before-publishing',
      abbr: 'a',
      help: 'Ask for confirmation before publishing to pub.dev.',
      defaultsTo: true,
      negatable: true,
    );

    argParser.addFlag(
      'increase-version',
      abbr: 'c',
      help: 'Increase version after publishing.',
      defaultsTo: true,
      negatable: true,
    );

    argParser.addFlag(
      'delete-feature-branch',
      help: 'Delete the feature branch on origin',
      defaultsTo: true,
      negatable: true,
    );

    argParser.addFlag(
      panaOption,
      help: 'Run »dart run pana« as part of »can publish«.',
      defaultsTo: true,
      negatable: true,
    );

    argParser.addFlag(
      'pr',
      help: 'Merge via auto-merge pull request (default)',
      defaultsTo: true,
      negatable: true,
    );

    argParser.addOption(
      'message',
      abbr: 'm',
      help: 'The message of the final merge commit',
    );

    argParser.addOption(
      'config',
      help: 'Path to a .gg-publish.json to publish with',
    );

    argParser.addOption(
      'channel',
      help: 'The release channel: stable or rc',
      allowed: allowedReleaseChannels,
    );

    argParser.addFlag(
      'continue',
      help: 'Resume a failed publish where it stopped',
      defaultsTo: false,
      negatable: false,
    );

    argParser.addFlag(
      'restart',
      help: 'Discard the saved config and configure again',
      defaultsTo: false,
      negatable: true,
    );

    argParser.addFlag(
      'merge-only',
      help: 'Merge without releasing: no version bump, no tag.',
      defaultsTo: false,
      negatable: false,
    );

    argParser.addFlag(
      'force',
      help: 'Merge although local refs are still in place.',
      defaultsTo: false,
      negatable: false,
    );

    argParser.addFlag(
      'verbose',
      abbr: 'v',
      help: 'Prints each executed command before running it.',
      defaultsTo: false,
      negatable: false,
    );
  }
}

/// Mock for [DoPublish].
class MockDoPublish extends MockDirCommand<void> implements DoPublish {}
