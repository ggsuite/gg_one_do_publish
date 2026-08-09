// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one_do_publish/gg_one_do_publish.dart';
import 'package:gg_process/gg_process.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

void main() {
  late Directory d;
  final messages = <String>[];
  final GgLog ggLog = messages.add;
  late DidPublish didPublish;

  Future<void> git(List<String> args) async {
    final result = await Process.run('git', args, workingDirectory: d.path);
    if (result.exitCode != 0) {
      throw Exception('git ${args.join(' ')} failed: ${result.stderr}');
    }
  }

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

  group('DidPublish', () {
    group('get(directory)', () {
      test('is false while nothing is tagged yet', () async {
        expect(await didPublish.get(directory: d, ggLog: ggLog), isFalse);
        expect(messages.join('\n'), contains('No release is tagged yet'));
      });

      test('is true when the last user commit is covered by a tag', () async {
        await git(['tag', '1.0.0']);
        expect(await didPublish.get(directory: d, ggLog: ggLog), isTrue);
      });

      test('stays true for gg bookkeeping added after the tag', () async {
        await git(['tag', '1.0.0']);
        // A publish leaves these behind — they are not work, so they do not
        // make the release stale.
        await addAndCommitSampleFile(
          d,
          fileName: 'pubspec.lock',
          content: 'generated',
          message: '#gg: restored local workspace references',
        );
        await addAndCommitSampleFile(
          d,
          fileName: 'CHANGELOG.md',
          content: '# Changelog',
          message: 'gg_multi: changed references to path',
        );

        expect(await didPublish.get(directory: d, ggLog: ggLog), isTrue);
      });

      test('is false once real work follows the tag', () async {
        await git(['tag', '1.0.0']);
        await addAndCommitSampleFile(
          d,
          fileName: 'lib.dart',
          content: 'void main() {}',
          message: 'Fix login bug',
        );

        expect(await didPublish.get(directory: d, ggLog: ggLog), isFalse);
        expect(
          messages.join('\n'),
          contains('»lib.dart« differs from the release 1.0.0'),
        );
      });

      test('survives a squash merge — the tag is not reachable', () async {
        // gg squash-merges the feature branch into main, so the tagged
        // commit is no ancestor of the feature branch. Ancestry would say
        // »not released« although the content is exactly what was released.
        await git(['checkout', '-b', 'feat']);
        await addAndCommitSampleFile(
          d,
          fileName: 'lib.dart',
          content: 'void main() {}',
          message: 'My work',
        );
        final tree = await Process.run('git', [
          'rev-parse',
          'HEAD:',
        ], workingDirectory: d.path);
        final mainSha = await Process.run('git', [
          'rev-parse',
          'main',
        ], workingDirectory: d.path);
        final squash = await Process.run('git', [
          'commit-tree',
          (tree.stdout as String).trim(),
          '-p',
          (mainSha.stdout as String).trim(),
          '-m',
          'Release',
        ], workingDirectory: d.path);
        final squashSha = (squash.stdout as String).trim();
        await git(['update-ref', 'refs/heads/main', squashSha]);
        await git(['tag', '2.0.0', squashSha]);

        expect(await didPublish.get(directory: d, ggLog: ggLog), isTrue);
      });

      test('is false while user work is uncommitted', () async {
        await git(['tag', '1.0.0']);
        File('${d.path}/lib.dart').writeAsStringSync('void main() {}');

        expect(await didPublish.get(directory: d, ggLog: ggLog), isFalse);
        expect(messages.join('\n'), contains('»lib.dart« is not committed'));
      });

      test('tolerates dirt in gg-owned files', () async {
        await addAndCommitSampleFile(
          d,
          fileName: 'pubspec.lock',
          content: 'one',
        );
        await git(['tag', '1.0.0']);
        // A background »pub get« rewrites lock files, and the workspace
        // overrides a publish restores at its end are gg's wiring — neither
        // is work, so neither makes the release stale.
        File('${d.path}/pubspec.lock').writeAsStringSync('two');
        File('${d.path}/pubspec_overrides.yaml').writeAsStringSync('x');

        expect(await didPublish.get(directory: d, ggLog: ggLog), isTrue);
      });

      test('reports plainly when the directory is no git repository', () async {
        final noRepo = await Directory.systemTemp.createTemp();
        addTearDown(() => noRepo.deleteSync(recursive: true));
        await expectLater(
          didPublish.get(directory: noRepo, ggLog: ggLog),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('not a git repository'),
            ),
          ),
        );
      });

      test('throws when git itself fails', () async {
        final processWrapper = MockGgProcessWrapper();
        when(
          () => processWrapper.run(
            'git',
            any(),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer((_) async => ProcessResult(1, 1, '', 'git is unhappy'));

        final failing = DidPublish(
          ggLog: messages.add,
          processWrapper: processWrapper,
        );

        await expectLater(
          failing.get(directory: d, ggLog: ggLog),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('git is unhappy'),
            ),
          ),
        );
      });
    });

    group('exec(directory)', () {
      test('stays quiet when the state is published', () async {
        await git(['tag', '1.0.0']);
        expect(await didPublish.exec(directory: d, ggLog: ggLog), isTrue);
        expect(messages.join('\n'), isNot(contains('Not published yet')));
      });

      test('prints the suggestion and the reason otherwise', () async {
        expect(await didPublish.exec(directory: d, ggLog: ggLog), isFalse);
        final log = messages.join('\n');
        expect(log, contains('Not published yet'));
        expect(log, contains('No release is tagged yet'));
      });
    });
  });
}
