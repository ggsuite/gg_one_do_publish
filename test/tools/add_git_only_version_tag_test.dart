// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git.dart';
import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_one_do_publish/gg_one_do_publish.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:gg_version/gg_version.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockGgProcessWrapper extends Mock implements GgProcessWrapper {}

void main() {
  late Directory d;
  late AddGitOnlyVersionTag command;
  final messages = <String>[];

  setUpAll(() {
    registerFallbackValue(<String>[]);
  });

  setUp(() async {
    messages.clear();
    d = Directory.systemTemp.createTempSync('add_git_only_version_tag_');
    command = AddGitOnlyVersionTag(ggLog: messages.add);
  });

  tearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });

  // ...........................................................................
  /// Returns all tags of the repo in [d].
  Future<List<String>> tags() async {
    final result = await Process.run('git', ['tag'], workingDirectory: d.path);
    return result.stdout
        .toString()
        .split('\n')
        .where((t) => t.isNotEmpty)
        .toList();
  }

  // ...........................................................................
  /// Copies a cached, tag-free repo with one committed sample file into [d].
  Future<void> initRepo() => initCachedRepo(
    d,
    key: 'tag_base',
    build: (repo) async {
      await initGit(repo);
      await addAndCommitSampleFile(repo);
    },
  );

  group('AddGitOnlyVersionTag', () {
    group('exec(directory, increment, channel)', () {
      group('should tag HEAD', () {
        test('with 0.0.1 when the repo has no version tag yet', () async {
          await initRepo();

          await command.exec(directory: d, increment: VersionIncrement.patch);

          expect(await tags(), ['0.0.1']);
          expect(messages.last, contains('Tag 0.0.1 added.'));
        });

        test('with the incremented latest version tag', () async {
          await initRepo();
          await addTags(d, ['0.0.1']);

          await updateAndCommitSampleFile(d);
          await command.exec(directory: d, increment: VersionIncrement.minor);
          expect(await tags(), contains('0.1.0'));

          await updateAndCommitSampleFile(d);
          await command.exec(directory: d, increment: VersionIncrement.major);
          expect(await tags(), contains('1.0.0'));
        });

        test('also when tags sort differently as strings', () async {
          await initRepo();
          await addTags(d, ['9.0.0']);
          await updateAndCommitSampleFile(d);
          await addTags(d, ['10.0.0']);

          await updateAndCommitSampleFile(d);
          await command.exec(directory: d, increment: VersionIncrement.patch);

          expect(await tags(), contains('10.0.1'));
        });

        test('with an rc version when the channel is rc', () async {
          await initRepo();
          await addTags(d, ['0.0.1']);

          await updateAndCommitSampleFile(d);
          await command.exec(
            directory: d,
            increment: VersionIncrement.patch,
            channel: ReleaseChannel.rc,
          );
          expect(await tags(), contains('0.0.2-rc.1'));

          await updateAndCommitSampleFile(d);
          await command.exec(
            directory: d,
            increment: VersionIncrement.patch,
            channel: ReleaseChannel.rc,
          );
          expect(await tags(), contains('0.0.2-rc.2'));
        });
      });

      group('should do nothing', () {
        test('when HEAD already carries a version tag', () async {
          await initRepo();
          await addTags(d, ['0.0.1']);

          await command.exec(directory: d, increment: VersionIncrement.patch);

          expect(await tags(), ['0.0.1']);
          expect(messages.last, contains('Version 0.0.1 tag already present.'));
        });
      });

      test('.example builds a usable instance', () {
        expect(AddGitOnlyVersionTag.example(), isA<AddGitOnlyVersionTag>());
      });

      group('should throw', () {
        test('when not everything is committed', () async {
          await initRepo();
          await addFileWithoutCommitting(d);

          await expectLater(
            () => command.exec(directory: d, increment: VersionIncrement.patch),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('Not everything is commited.'),
              ),
            ),
          );
        });

        test('when git tag fails', () async {
          await initRepo();

          final processWrapper = _MockGgProcessWrapper();
          when(() => processWrapper.run('git', any(), workingDirectory: d.path))
              .thenAnswer((_) async => ProcessResult(1, 1, '', 'tag error'));

          final failing = AddGitOnlyVersionTag(
            ggLog: messages.add,
            isCommitted: IsCommitted(ggLog: messages.add),
            fromGit: FromGit(ggLog: messages.add),
            processWrapper: processWrapper,
          );

          await expectLater(
            () => failing.exec(directory: d, increment: VersionIncrement.patch),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('Could not add tag 0.0.1'),
              ),
            ),
          );
        });
      });
    });
  });
}
