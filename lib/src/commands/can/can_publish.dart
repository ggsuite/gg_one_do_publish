// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_state/gg_one_state.dart';
import 'package:gg_args/gg_args.dart';
import 'package:gg_changelog/gg_changelog.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_one_checks/gg_one_checks.dart';
import 'package:gg_one_commit/gg_one_commit.dart';

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
           pana ?? Pana(ggLog: ggLog, publishedOnly: true),
           npmLoggedIn ?? NpmLoggedIn(ggLog: ggLog),
         ],
       );
}

// .............................................................................
/// A mocktail mock
class MockCanPublish extends MockDirCommand<void> implements CanPublish {}
