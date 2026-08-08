// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_version/gg_version.dart';
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:pub_semver/pub_semver.dart';

/// Tags HEAD with the next version for a project without a manifest — the
/// git-only counterpart to `gg_version.AddVersionTag`. The version lives
/// exclusively in git tags: the next version is the latest version tag plus
/// [VersionIncrement]; without any tag the first version is `0.0.1` (patch).
/// Idempotent: a HEAD that already carries a version tag is left untouched.
class AddGitOnlyVersionTag {
  /// Constructor.
  AddGitOnlyVersionTag({
    required this.ggLog,
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
    IsCommitted? isCommitted,
    FromGit? fromGit,
    PrepareNextVersion? prepareNextVersion,
  }) : _processWrapper = processWrapper,
       _isCommitted =
           isCommitted ??
           IsCommitted(ggLog: ggLog, processWrapper: processWrapper),
       _fromGit = fromGit ?? FromGit(ggLog: ggLog),
       _prepareNextVersion =
           prepareNextVersion ?? PrepareNextVersion(ggLog: ggLog);

  // ...........................................................................
  /// Computes the next version from the latest git version tag and tags HEAD
  /// with it. Throws when the directory has uncommitted changes or when
  /// `git tag` fails.
  Future<void> exec({
    required Directory directory,
    required VersionIncrement increment,
    ReleaseChannel channel = ReleaseChannel.stable,
    Map<String, dynamic> options = const {},
  }) async {
    // Throw if not everything is committed.
    final isCommitted = await _isCommitted.get(
      directory: directory,
      ggLog: ggLog,
    );
    if (!isCommitted) {
      throw StateError('Not everything is commited.');
    }

    // A resumed publish may already have tagged HEAD — do nothing then.
    final headVersion = await _fromGit.fromHead(
      ggLog: ggLog,
      directory: directory,
    );
    if (headVersion != null) {
      ggLog(cDetail('Version $headVersion tag already present.'));
      return;
    }

    // Next version = latest version tag + increment; 0.0.0 without any tag,
    // so the first patch release becomes 0.0.1.
    final latest =
        await _fromGit.latest(ggLog: ggLog, directory: directory) ??
        Version(0, 0, 0);
    final all = await _fromGit.allVersions(ggLog: ggLog, directory: directory);

    final next = await _prepareNextVersion.nextVersion(
      directory: directory,
      ggLog: ggLog,
      increment: increment,
      channel: channel,
      publishedVersion: latest,
      allPublishedVersions: all,
    );

    final version = next.toString();
    final result = await _processWrapper.run('git', <String>[
      'tag',
      '-a',
      version,
      '-m',
      'Version $version',
    ], workingDirectory: directory.path);

    if (result.exitCode != 0) {
      throw Exception(
        cError(
          'Could not add tag $version in ${directory.path}: ${result.stderr}',
        ),
      );
    }
    ggLog(cDetail('Tag $version added.'));
  }

  /// One status line per `exec`: `Tag <v> added.` or `… already present.`.
  final GgLog ggLog;

  /// Example instance for tests — logs to `print`, default process wrapper.
  factory AddGitOnlyVersionTag.example() => AddGitOnlyVersionTag(ggLog: print);

  // ######################
  // Private
  // ######################

  final GgProcessWrapper _processWrapper;
  final IsCommitted _isCommitted;
  final FromGit _fromGit;
  final PrepareNextVersion _prepareNextVersion;
}

/// Mock for [AddGitOnlyVersionTag].
class MockAddGitOnlyVersionTag extends mocktail.Mock
    implements AddGitOnlyVersionTag {}
