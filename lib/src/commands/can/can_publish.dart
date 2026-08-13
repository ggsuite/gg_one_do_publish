// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_args/gg_args.dart';
import 'package:gg_changelog/gg_changelog.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:gg_one_commit/gg_one_commit.dart';

/// The [DirCommand.exec] option deciding whether pana is run.
///
/// `true` (the default) runs it, `false` skips it. It travels through the
/// `options` map of `exec`, so every caller — `gg do publish`, gg_multi's
/// `can publish` and `do publish` — can turn pana off without any of the
/// commands in between growing a parameter.
const String panaOption = 'pana';

/// Are the last changes ready to be published?
class CanPublish extends CommandCluster {
  /// Constructor
  CanPublish({
    required super.ggLog,
    super.name = 'publish',
    super.description = 'Check if this repo can be published',
    super.shortDescription = 'Can publish?',
    super.stateKey = 'canPublish',
    DidCommit? didCommit,
    Pana? pana,
    HasRightFormat? changeLogHasRightFormat,
    IsFeatureBranch? isFeatureBranch,
    NpmLoggedIn? npmLoggedIn,
    NoPubspecOverrides? noPubspecOverrides,
    PubGetOffline? pubGetOffline,
  }) : super(
         commands: [
           // Runs first, exactly as in CanCommit: the lock file is tracked, so
           // a background `pub get` — the Dart VS Code extension fires one
           // whenever a manifest is written — leaves it modified and the
           // `didCommit` below would refuse to publish over a file nobody
           // edited. Syncing it with the manifest first removes that noise.
           pubGetOffline ?? PubGetOffline(ggLog: ggLog),
           isFeatureBranch ?? IsFeatureBranch(ggLog: ggLog),
           noPubspecOverrides ?? NoPubspecOverrides(ggLog: ggLog),
           changeLogHasRightFormat ?? HasRightFormat(ggLog: ggLog),
           didCommit ?? DidCommit(ggLog: ggLog),
           OptionalPana(
             ggLog: ggLog,
             pana: pana ?? Pana(ggLog: ggLog, publishedOnly: true),
           ),
           npmLoggedIn ?? NpmLoggedIn(ggLog: ggLog),
         ],
       ) {
    _addArgs();
  }

  // ...........................................................................
  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? force,
    bool? saveState,
    Map<String, dynamic> options = const {},
  }) => super.get(
    directory: directory,
    ggLog: ggLog,
    force: force,
    saveState: saveState,
    options: resolveOptions(options),
  );

  // ...........................................................................
  /// Fills [panaOption] into [options] when the caller did not decide.
  ///
  /// An explicitly passed option always wins — only when it is absent does
  /// `--[no-]pana` from the command line apply, defaulting to running pana.
  Map<String, dynamic> resolveOptions(Map<String, dynamic> options) {
    if (options.containsKey(panaOption)) {
      return options;
    }

    return <String, dynamic>{
      ...options,
      panaOption: argResults?[panaOption] as bool? ?? true,
    };
  }

  // ...........................................................................
  void _addArgs() {
    argParser.addFlag(
      panaOption,
      help: 'Run »dart run pana«.',
      defaultsTo: true,
      negatable: true,
    );
  }
}

// .............................................................................
/// Runs [pana] unless the [panaOption] of `exec` turns it off.
///
/// [Pana] itself takes no options, so the skip lives in this wrapper — that
/// keeps the decision where the option arrives (the `exec` call of the
/// command cluster) instead of inside the analysis command.
class OptionalPana extends DirCommand<void> {
  /// Constructor
  OptionalPana({required super.ggLog, required this.pana})
    : super(
        name: 'pana',
        description: 'Runs »dart run pana« unless --no-pana is given.',
      );

  /// The wrapped pana command
  final Pana pana;

  // ...........................................................................
  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    Map<String, dynamic> options = const {},
  }) async {
    if (options[panaOption] == false) {
      GgStatusPrinter<void>(
        ggLog: ggLog,
        message: 'Skipping pana (--no-pana)',
        dark: true,
      ).logStatus(GgStatusPrinterStatus.success);
      return;
    }

    await pana.exec(directory: directory, ggLog: ggLog, options: options);
  }

  // ...........................................................................
  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) =>
      pana.get(directory: directory, ggLog: ggLog);
}

// .............................................................................
/// A mocktail mock
class MockCanPublish extends MockDirCommand<void> implements CanPublish {}
