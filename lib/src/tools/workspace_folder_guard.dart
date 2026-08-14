// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:path/path.dart' as path;

/// The name of the ticket description file gg_multi writes into a ticket
/// folder (`<root>/tickets/<ticket>/ticket.json`).
const String ticketJsonFileName = 'ticket.json';

/// The extension of the VS Code workspace file of a ticket folder
/// (`<root>/tickets/<ticket>/<ticket>.code-workspace`).
const String codeWorkspaceExtension = '.code-workspace';

/// Returns true when [directory] is a ticket workspace folder rather than a
/// repository.
///
/// A ticket folder holds the repositories of a ticket plus gg_multi's
/// bookkeeping — a [ticketJsonFileName] and a `<ticket>.code-workspace` file —
/// but is no git repository itself. The missing `.git` is what separates it
/// from a repository that merely carries a `.code-workspace` file of its own.
bool isWorkspaceFolder(Directory directory) {
  if (Directory(path.join(directory.path, '.git')).existsSync() ||
      File(path.join(directory.path, '.git')).existsSync()) {
    return false;
  }

  if (File(path.join(directory.path, ticketJsonFileName)).existsSync()) {
    return true;
  }

  return directory.existsSync() &&
      directory.listSync().whereType<File>().any(
        (e) => path.basename(e.path).endsWith(codeWorkspaceExtension),
      );
}

/// Throws when [directory] is a ticket workspace folder.
///
/// »gg do publish« publishes one repository. Run in the ticket folder itself
/// it would operate on a directory that is no git repository at all and fail
/// with confusing git errors. The whole ticket is published by gg_multi
/// instead, which publishes its repositories in dependency order.
void throwWhenInWorkspaceFolder(Directory directory) {
  if (!isWorkspaceFolder(directory)) {
    return;
  }

  // The whole line is an error; only the folder and the commands to run
  // next carry their own semantic color.
  throw Exception(
    cError(
      'Cannot run '
      '${cCmd('gg do publish')}'
      ' inside the ticket workspace folder '
      '${cPath('»${path.basename(directory.absolute.path)}«')}'
      '.\n'
      'Publish a single repository from within its own folder.\n'
      'Or publish the whole ticket using '
      '${cCmd('gg multi do publish')}',
    ),
  );
}
