// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_process/gg_process.dart';
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:path/path.dart';

/// Tags HEAD with the `version` field of a TS `package.json` — the TS
/// counterpart to `gg_version.AddVersionTag`. Idempotent.
class AddTypeScriptVersionTag {
  /// Constructor.
  AddTypeScriptVersionTag({
    required this.ggLog,
    GgProcessWrapper processWrapper = const GgProcessWrapper(),
  }) : _processWrapper = processWrapper;

  // ...........................................................................
  /// Reads `package.json` version and tags HEAD. Throws on `git tag` failure.
  Future<void> exec({
    required Directory directory,
    Map<String, dynamic> options = const {},
  }) async {
    final version = _readPackageJsonVersion(directory);
    if (version == null) return;

    if (await _headAlreadyHasTag(directory: directory, tag: version)) {
      ggLog(cDetail('Version $version tag already present.'));
      return;
    }

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
  factory AddTypeScriptVersionTag.example() =>
      AddTypeScriptVersionTag(ggLog: print);

  // ######################
  // Private
  // ######################

  // ...........................................................................

  final GgProcessWrapper _processWrapper;

  // ...........................................................................
  /// Reads `version` from `package.json`, or null on any miss. Inlined
  /// (not via `gg_localize_refs.PackageJsonIo`) to keep gg_one independent.
  String? _readPackageJsonVersion(Directory directory) {
    final pkg = File(join(directory.path, 'package.json'));
    if (!pkg.existsSync()) return null;
    try {
      final decoded = jsonDecode(pkg.readAsStringSync());
      if (decoded is! Map) return null;
      final version = decoded['version'];
      if (version is! String || version.isEmpty) return null;
      return version;
    } catch (_) {
      return null;
    }
  }

  // ...........................................................................
  /// Whether HEAD already has a git tag named exactly [tag].
  Future<bool> _headAlreadyHasTag({
    required Directory directory,
    required String tag,
  }) async {
    final existing = await _processWrapper.run('git', <String>[
      'tag',
      '--points-at',
      'HEAD',
    ], workingDirectory: directory.path);
    return existing.stdout
        .toString()
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .contains(tag);
  }
}

/// Mock for [AddTypeScriptVersionTag].
class MockAddTypeScriptVersionTag extends mocktail.Mock
    implements AddTypeScriptVersionTag {}
