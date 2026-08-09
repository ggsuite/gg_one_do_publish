// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';

/// Is the current state published?
///
/// Answered from git, not from a recorded marker: a release is what a **tag**
/// marks, so the question is whether what sits here is the tagged content.
/// The answer is yes when nothing but gg's own files differs — neither in the
/// working tree nor between HEAD and the last release of the default branch.
/// gg's bookkeeping does not count, because it is not work.
///
/// Everything is decided on **object ids**, never on file contents: an equal
/// tree hash answers the question outright, and the entry-level comparison
/// that follows an unequal one compares blob hashes too.
///
/// Earlier gg versions recorded a `didPublish` state instead. That marker was
/// also written when `gg do publish` **skipped** a repository, so it claimed
/// »released« for content that could still be sitting unreleased on the main
/// branch. The key is pruned from `.gg/gg.json` now
/// ([GgState.obsoleteKeys]); nothing writes it any more.
class DidPublish extends DirCommand<bool> {
  /// Constructor
  DidPublish({
    required super.ggLog,
    super.name = 'publish',
    super.description = 'Check if the current state was published',
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
  }) : _processWrapper = processWrapper;

  /// What the user is told when the answer is no.
  static const String suggestion =
      'Not published yet. Please run »gg do publish«.';

  final GgProcessWrapper _processWrapper;

  // ...........................................................................
  @override
  Future<bool> exec({
    required Directory directory,
    required GgLog ggLog,
    Map<String, dynamic> options = const {},
  }) async {
    final messages = <String>[];

    final result =
        await GgStatusPrinter<bool>(
          message: 'State is published',
          ggLog: ggLog,
          dark: true,
        ).logTask(
          task: () => get(directory: directory, ggLog: messages.add),
          success: (success) => success,
        );

    if (!result) {
      final details = messages.join('\n').trim();
      ggLog(
        <String>[
          colorizeSuggestion(suggestion),
          if (details.isNotEmpty) cDetail(details),
        ].join('\n'),
      );
    }

    return result;
  }

  // ...........................................................................
  /// Whether everything committed here is covered by a version tag.
  @override
  Future<bool> get({required Directory directory, required GgLog ggLog}) async {
    await check(directory: directory);

    // Uncommitted work is by definition not released — but only *work*
    // counts. gg's own files do not: a background »pub get« rewrites lock
    // files, and the workspace overrides a publish restores at its end are
    // gg's wiring, not something the user wrote. Same predicate the system
    // commits use to decide what they may contain.
    // Raw, not trimmed: the porcelain columns are positional and a leading
    // space is meaningful (» M file« is modified but unstaged).
    final status = await _git(
      directory,
      const ['status', '--porcelain', '--untracked-files=all'],
      'read the working tree status',
      trimmed: false,
    );
    for (final entry in parseGitStatus(status)) {
      final foreign = entry.paths.where((p) => !isGgOwnedPath(p));
      if (foreign.isNotEmpty) {
        ggLog('»${foreign.first}« is not committed.');
        return false;
      }
    }

    // The tag sits on the default branch. A squash merge makes it
    // unreachable from the feature branch — the squash is a new commit — so
    // ancestry says nothing here. The *content* does: the squash takes the
    // feature tree verbatim, so »is what I have here released?« is answered
    // by comparing this tree against the last released one.
    final mainRef = await _defaultBranch(directory);
    final lastTag = await _git(
      directory,
      <String>['describe', '--tags', '--abbrev=0', ?mainRef],
      'find the last version tag',
      allowFailure: true,
    );
    if (lastTag.isEmpty) {
      ggLog('No release is tagged yet.');
      return false;
    }

    // Hash comparison, never file contents: git identifies a whole tree by
    // one object id, so identical content is a single string equality.
    final releasedTree = await _git(directory, <String>[
      'rev-parse',
      '$lastTag^{tree}',
    ], 'read the tree of $lastTag');
    final currentTree = await _git(directory, const <String>[
      'rev-parse',
      'HEAD^{tree}',
    ], 'read the tree of HEAD');
    if (releasedTree == currentTree) {
      return true;
    }

    // The trees differ — list *which* entries, again by object id
    // (`diff-tree` compares hashes and never reads a file). gg's own files
    // may differ: the release bumps the version and rewrites lock files.
    final changed = await _git(directory, <String>[
      'diff-tree',
      '-r',
      '--name-only',
      lastTag,
      'HEAD',
    ], 'compare the tree against $lastTag');
    for (final line in changed.split('\n')) {
      final file = line.trim();
      if (file.isEmpty || isGgOwnedPath(file)) {
        continue;
      }
      ggLog('»$file« differs from the release $lastTag.');
      return false;
    }

    return true;
  }

  // ...........................................................................
  /// The default branch to read the last release from — `origin/<main>`
  /// first, the local branch as fallback. Null when neither exists, which
  /// leaves `git describe` to answer for HEAD.
  Future<String?> _defaultBranch(Directory directory) async {
    for (final candidate in const [
      'origin/main',
      'origin/master',
      'main',
      'master',
    ]) {
      final sha = await _git(
        directory,
        <String>['rev-parse', '--verify', '--quiet', candidate],
        'resolve $candidate',
        allowFailure: true,
      );
      if (sha.isNotEmpty) {
        return candidate;
      }
    }
    return null;
  }

  // ...........................................................................
  Future<String> _git(
    Directory directory,
    List<String> arguments,
    String description, {
    bool allowFailure = false,
    bool trimmed = true,
  }) async {
    final result = await _processWrapper.run(
      'git',
      arguments,
      workingDirectory: directory.path,
    );
    if (result.exitCode != 0) {
      if (allowFailure) {
        return '';
      }
      throw Exception('Could not $description: ${result.stderr}');
    }
    final out = result.stdout.toString();
    return trimmed ? out.trim() : out;
  }
}

/// Mock for [DidPublish]
class MockDidPublish extends MockDirCommand<bool> implements DidPublish {}
