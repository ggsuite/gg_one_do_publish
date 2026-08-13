// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_one_do_publish/src/tools/add_typescript_version_tag.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

class _MockGgProcessWrapper extends Mock implements GgProcessWrapper {}

void main() {
  // mocktail `any()` for `List<String>` needs a registered fallback.
  setUpAll(() {
    registerFallbackValue(<String>[]);
  });

  group('AddTypeScriptVersionTag', () {
    late Directory tmp;
    late _MockGgProcessWrapper processWrapper;
    late AddTypeScriptVersionTag command;
    final messages = <String>[];

    File packageJson() => File(join(tmp.path, 'package.json'));

    setUp(() {
      messages.clear();
      tmp = Directory.systemTemp.createTempSync('add_ts_version_tag_');
      processWrapper = _MockGgProcessWrapper();
      command = AddTypeScriptVersionTag(
        ggLog: messages.add,
        processWrapper: processWrapper,
      );
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    // .........................................................................
    /// Stubs `git tag --points-at HEAD` to return the given multi-line string.
    void stubExistingTags(String stdout) {
      when(
        () => processWrapper.run('git', <String>[
          'tag',
          '--points-at',
          'HEAD',
        ], workingDirectory: tmp.path),
      ).thenAnswer((_) async => ProcessResult(0, 0, stdout, ''));
    }

    /// Stubs `git tag -a <version> -m "Version <version>"` with the given
    /// exit code + stderr.
    void stubTagCreation(
      String version, {
      int exitCode = 0,
      String stderr = '',
    }) {
      when(
        () => processWrapper.run('git', <String>[
          'tag',
          '-a',
          version,
          '-m',
          'Version $version',
        ], workingDirectory: tmp.path),
      ).thenAnswer((_) async => ProcessResult(0, exitCode, '', stderr));
    }

    // .........................................................................
    group('is a no-op', () {
      test('when package.json does not exist', () async {
        // No File written.
        await command.exec(directory: tmp);
        expect(messages, isEmpty);
        verifyNever(
          () => processWrapper.run(
            any(),
            any(),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        );
      });

      test('never touches git when there is nothing to tag '
          '(e.g. version is missing)', () async {
        packageJson().writeAsStringSync('{"name":"@x/y"}');
        await command.exec(directory: tmp);
        verifyNever(
          () => processWrapper.run(
            any(),
            any(),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        );
      });

      test('when package.json is not valid JSON', () async {
        packageJson().writeAsStringSync('{not json');
        await command.exec(directory: tmp);
        expect(messages, isEmpty);
      });

      test('when package.json is a JSON array (not an object)', () async {
        packageJson().writeAsStringSync('["not", "an", "object"]');
        await command.exec(directory: tmp);
        expect(messages, isEmpty);
      });

      test('when the "version" field is missing', () async {
        packageJson().writeAsStringSync('{"name":"@x/y"}');
        await command.exec(directory: tmp);
        expect(messages, isEmpty);
      });

      test('when the "version" field is not a string', () async {
        packageJson().writeAsStringSync('{"name":"@x/y","version":123}');
        await command.exec(directory: tmp);
        expect(messages, isEmpty);
      });

      test('when the "version" field is the empty string', () async {
        packageJson().writeAsStringSync('{"name":"@x/y","version":""}');
        await command.exec(directory: tmp);
        expect(messages, isEmpty);
      });
    });

    // .........................................................................
    group('skips tag creation', () {
      test('when HEAD already carries the exact version tag', () async {
        packageJson().writeAsStringSync('{"name":"@x/y","version":"1.2.3"}');
        // CRLF on Windows is tolerated by the splitter.
        stubExistingTags('something-unrelated\r\n1.2.3\r\n');

        await command.exec(directory: tmp);

        expect(messages, [cDetail('Version 1.2.3 tag already present.')]);
        // `any(that:)` matches the `tag -a …` creation call by its prefix.
        verifyNever(
          () => processWrapper.run(
            'git',
            any(
              that: allOf(
                isA<List<String>>(),
                contains('-a'),
                contains('tag'),
                isNot(contains('--points-at')),
              ),
            ),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        );
      });
    });

    // .........................................................................
    group('creates the tag', () {
      test('when HEAD has no version tag yet', () async {
        packageJson().writeAsStringSync('{"name":"@x/y","version":"0.1.3"}');
        stubExistingTags('');
        stubTagCreation('0.1.3');

        await command.exec(directory: tmp);

        expect(messages, [cDetail('Tag 0.1.3 added.')]);
        verify(
          () => processWrapper.run('git', <String>[
            'tag',
            '-a',
            '0.1.3',
            '-m',
            'Version 0.1.3',
          ], workingDirectory: tmp.path),
        ).called(1);
      });

      test(
        'uses the package.json version verbatim, including pre-releases',
        () async {
          packageJson().writeAsStringSync(
            '{"name":"@x/y","version":"2.0.0-beta.4"}',
          );
          stubExistingTags('');
          stubTagCreation('2.0.0-beta.4');

          await command.exec(directory: tmp);

          expect(messages, [cDetail('Tag 2.0.0-beta.4 added.')]);
        },
      );

      test('ignores unrelated tags on HEAD when deciding to create', () async {
        packageJson().writeAsStringSync('{"name":"@x/y","version":"0.1.3"}');
        // HEAD has tags, but none of them match the package version.
        stubExistingTags('0.1.2\nrelease-2026-06-09\n');
        stubTagCreation('0.1.3');

        await command.exec(directory: tmp);

        expect(messages, [cDetail('Tag 0.1.3 added.')]);
      });
    });

    // .........................................................................
    group('reports failure', () {
      test(
        'when `git tag` exits non-zero — wrapping stderr in the exception',
        () async {
          packageJson().writeAsStringSync('{"name":"@x/y","version":"0.1.3"}');
          stubExistingTags('');
          stubTagCreation('0.1.3', exitCode: 128, stderr: 'tag already exists');

          await expectLater(
            command.exec(directory: tmp),
            throwsA(
              isA<Exception>()
                  .having(
                    (e) => rmControls(e.toString()),
                    'message',
                    contains('Could not add tag 0.1.3'),
                  )
                  .having(
                    (e) => rmControls(e.toString()),
                    'message',
                    contains('tag already exists'),
                  ),
            ),
          );
          expect(messages, isEmpty);
        },
      );
    });

    // .........................................................................
    test('uses the default GgProcessWrapper when none is injected', () {
      // Smoke-test the default-parameter branch.
      expect(
        AddTypeScriptVersionTag(ggLog: (_) {}),
        isA<AddTypeScriptVersionTag>(),
      );
    });

    // .........................................................................
    test('.example builds a usable instance', () {
      expect(AddTypeScriptVersionTag.example(), isA<AddTypeScriptVersionTag>());
    });
  });
}
