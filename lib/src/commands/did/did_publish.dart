// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_core/gg_one_core.dart';

/// Is the current state published?
///
/// `gg do publish` records the state under `didPublish` — on the feature
/// branch immediately before the merge, so the merge itself carries it into
/// the main branch, and again once the workspace overrides are restored at
/// the end. The hash-based check therefore answers »is what I have here
/// released?«: any change after the publish makes it fail until the next
/// release. A merge-only run records nothing — it releases nothing.
///
/// The state key is `didPublish`, not the legacy `doPublish`:
/// that key belonged to the step bookkeeping of earlier gg versions and is
/// pruned from `.gg/gg.json` whenever a state is written.
class DidPublish extends DidCommand {
  /// Constructor
  DidPublish({
    required super.ggLog,
    super.name = 'publish',
    super.description = 'Check if the current state was published',
    super.shortDescription = 'State is published',
    super.suggestion = 'Not published yet. Please run »gg do publish«.',
    super.stateKey = 'didPublish',
  });
}

/// Mock for [DidPublish]
class MockDidPublish extends MockDidCommand implements DidPublish {}
