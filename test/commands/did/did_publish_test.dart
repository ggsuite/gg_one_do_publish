// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_do_publish/gg_one_do_publish.dart';
import 'package:test/test.dart';
import 'package:gg_one_core/gg_one_core.dart';

void main() {
  late Directory d;
  final messages = <String>[];
  GgLog ggLog = messages.add;
  late DidPublish didPublish;

  setUp(() async {
    messages.clear();
    d = await Directory.systemTemp.createTemp();
    await initGit(d);
    await addAndCommitSampleFile(d, fileName: 'pubspec.yaml');
    didPublish = DidPublish(ggLog: messages.add);
  });

  tearDown(() async {
    await d.delete(recursive: true);
  });

  group('did', () {
    group('Publish', () {
      test('works fine', () async {
        // Initially the command should return false,
        // because nothing was published
        expect(await didPublish.get(directory: d, ggLog: ggLog), isFalse);

        // Let's set a success state
        await didPublish.set(directory: d);

        // Now the command should return true
        expect(await didPublish.get(directory: d, ggLog: ggLog), isTrue);

        // A change after the publish invalidates the state
        await addAndCommitSampleFile(d, fileName: 'other.txt');
        expect(await didPublish.get(directory: d, ggLog: ggLog), isFalse);
      });

      test('uses the didPublish state key, not the pruned doPublish', () {
        // GgState removes the legacy »doPublish« key on every write —
        // a marker written under that name would silently disappear.
        expect(didPublish.stateKey, 'didPublish');
        expect(GgState.obsoleteKeys, contains('doPublish'));
        expect(GgState.obsoleteKeys, isNot(contains('didPublish')));
      });
    });
  });
}
