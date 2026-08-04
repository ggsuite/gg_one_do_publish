// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one_do_publish/gg_one_do_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory d;

  setUp(() {
    d = Directory.systemTemp.createTempSync('workspace_folder_guard');
  });

  tearDown(() {
    if (d.existsSync()) {
      d.deleteSync(recursive: true);
    }
  });

  void writeFile(String relativePath) {
    final file = File(path.join(d.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('');
  }

  group('isWorkspaceFolder(directory)', () {
    test('returns true for a folder containing a ticket.json', () {
      writeFile('ticket.json');
      expect(isWorkspaceFolder(d), isTrue);
    });

    test('returns true for a folder containing a .code-workspace file', () {
      writeFile('69.code-workspace');
      expect(isWorkspaceFolder(d), isTrue);
    });

    test('returns false for an empty folder', () {
      expect(isWorkspaceFolder(d), isFalse);
    });

    test('returns false for a folder that does not exist', () {
      d.deleteSync();
      expect(isWorkspaceFolder(d), isFalse);
    });

    test('returns false for a folder with other files only', () {
      writeFile('pubspec.yaml');
      expect(isWorkspaceFolder(d), isFalse);
    });

    test('returns false for a repository', () {
      // A repository may carry a .code-workspace file of its own. Its .git
      // folder is what separates it from a ticket folder.
      Directory(path.join(d.path, '.git')).createSync();
      writeFile('gg_one.code-workspace');
      expect(isWorkspaceFolder(d), isFalse);
    });

    test('returns false for a git worktree or submodule', () {
      // There .git is a file pointing to the real git folder.
      writeFile('.git');
      writeFile('ticket.json');
      expect(isWorkspaceFolder(d), isFalse);
    });
  });

  group('throwWhenInWorkspaceFolder(directory)', () {
    test('does not throw outside a workspace folder', () {
      expect(() => throwWhenInWorkspaceFolder(d), returnsNormally);
    });

    test('throws inside a workspace folder', () {
      writeFile('ticket.json');

      late String message;
      try {
        throwWhenInWorkspaceFolder(d);
      } catch (e) {
        message = rmControls(e.toString());
      }

      expect(message, contains('Cannot run '));
      expect(message, contains('gg do publish'));
      expect(message, contains(path.basename(d.path)));
      expect(message, contains('gg multi do publish'));
    });
  });
}
