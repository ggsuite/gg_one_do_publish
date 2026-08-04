// @license
// Copyright (c) 2019 - 2024 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_changelog/gg_changelog.dart';
import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_do_publish/gg_one_do_publish.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';
import 'package:gg_one_checks/gg_one_checks.dart';
import 'package:gg_one_commit/gg_one_commit.dart';

// .............................................................................
void main() {
  late Directory d;
  final messages = <String>[];
  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  late CanPublish canPublish;

  // ...........................................................................
  late Pana pana;
  late NpmLoggedIn npmLoggedIn;
  late DidCommit didCommit;
  late IsVersionPrepared isVersionPrepared;
  late HasRightFormat hasRightFormat;
  late PubGetOffline pubGetOffline;

  // ...........................................................................
  void mockCommands() {
    when(() => pubGetOffline.exec(directory: d, ggLog: ggLog)).thenAnswer((
      _,
    ) async {
      messages.add('pubGetOffline');
    });
    when(() => pana.exec(directory: d, ggLog: ggLog)).thenAnswer((_) async {
      messages.add('pana');
    });
    when(() => npmLoggedIn.exec(directory: d, ggLog: ggLog)).thenAnswer((
      _,
    ) async {
      messages.add('npmLoggedIn');
    });
    when(() => didCommit.exec(directory: d, ggLog: ggLog)).thenAnswer((
      _,
    ) async {
      messages.add('didCommit');
      return true;
    });
    when(() => isVersionPrepared.exec(directory: d, ggLog: ggLog)).thenAnswer((
      _,
    ) async {
      messages.add('isVersionPrepared');
      return true;
    });

    when(() => hasRightFormat.exec(directory: d, ggLog: ggLog)).thenAnswer((
      _,
    ) async {
      messages.add('hasRightFormat');
      return true;
    });
  }

  // ...........................................................................
  setUp(() async {
    pana = MockPana();
    npmLoggedIn = MockNpmLoggedIn();
    didCommit = MockDidCommit();
    isVersionPrepared = MockIsVersionPrepared();
    hasRightFormat = MockHasRightFormat();
    pubGetOffline = MockPubGetOffline();

    canPublish = CanPublish(
      ggLog: ggLog,
      pana: pana,
      npmLoggedIn: npmLoggedIn,
      didCommit: didCommit,
      pubGetOffline: pubGetOffline,
    );
    d = Directory.systemTemp.createTempSync();
    await initGit(d);
    await addAndCommitSampleFile(d);
    await createBranch(d, 'feat_abc');

    File(
      join(d.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: test\nrepository: https://foo.com');
  });

  // ...........................................................................
  tearDown(() {
    d.deleteSync(recursive: true);
  });

  // ...........................................................................
  group('CanPublish', () {
    group('run()', () {
      test('should run the sub commands except IsVersionPrepared', () async {
        mockCommands();
        await canPublish.exec(directory: d, ggLog: ggLog);
        var count = 0;
        // Runs first so the tracked lock file matches the manifest before
        // didCommit looks at the working tree.
        expect(messages[count++], 'pubGetOffline');
        expect(messages[count++], contains('Current branch is feature branch'));
        expect(messages[count++], contains('Current branch is feature branch'));
        expect(messages[count++], contains('⌛️ No pubspec_overrides.yaml'));
        expect(messages[count++], contains('✓ No pubspec_overrides.yaml'));
        expect(messages[count++], contains('⌛️ CHANGELOG.md has right format'));
        expect(messages[count++], contains('✓ CHANGELOG.md has right format'));
        expect(messages[count++], 'didCommit');
        expect(messages[count++], 'pana');
        expect(messages[count++], 'npmLoggedIn');
      });
    });

    test('should have a code coverage of 100%', () {
      expect(CanPublish(ggLog: ggLog), isNotNull);
    });
  });
}
