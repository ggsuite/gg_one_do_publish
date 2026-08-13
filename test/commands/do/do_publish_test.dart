// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// These are git-subprocess-heavy integration tests: setUp plus each
// DoPublish.exec spawn dozens of real `git` processes. Under the parallel
// coverage gate that contention can push the heaviest case past the default
// 30s per-test timeout (it passes comfortably in isolation / at -j1), so we
// give the whole file generous headroom.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_direct_json/gg_direct_json.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_merge/gg_merge.dart' as gg_merge;
import 'package:gg_one_do_publish/gg_one_do_publish.dart';
import 'package:gg_process/gg_process.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:gg_version/gg_version.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';
import 'package:gg_one_core/gg_one_core.dart';
import 'package:gg_one_commit/gg_one_commit.dart';
import 'package:gg_one_merge/gg_one_merge.dart';

void main() {
  final messages = <String>[];
  // Strip the colors so the expectations stay readable. One closure
  // instance, not a function declaration: mocktail matches the ggLog
  // argument by identity, and a tear-off is not stable.
  // ignore: prefer_function_declarations_over_variables
  final GgLog ggLog = (String msg) => messages.add(rmControls(msg));
  late Directory d;
  late Directory dRemote;
  late Directory Function() dMock;
  late DoPublish doPublish;
  late CanPublish canPublish;
  late PublishedVersion publishedVersion;
  late VersionSelector versionSelector;
  late MockGgProcessWrapper processWrapper;
  late MockLocalBranch localBranch;

  late int successHash;
  late int needsChangeHash;
  late Version publishedVersionValue;

  // ...........................................................................
  // Mocks
  late Publish publish;
  late MockWaitUntilPublished waitUntilPublished;
  // The dependency upgrade shells out to »dart pub upgrade« — mocked away
  // everywhere, its own behavior is covered in gg_one_commit.
  late MockDoUpgradeDeps upgradeDeps;

  Future<String?> defaultEditMessage(String initialMessage) async {
    return initialMessage;
  }

  Future<bool> defaultConfirmDeleteFeatureBranch(String branchName) async {
    return false;
  }

  // Returns the merge message of the default branch. The »doCommit« and
  // »didPublish« states are recorded before the merge and ride into main
  // inside the squash commit, so main usually ends exactly on the merge
  // message — but the main push may still add gg's own »#gg: …« state
  // bookkeeping on top when a hash was not aligned yet. HEAD itself ends up
  // back on the feature branch, so the history is read from `main`
  // explicitly.
  Future<String> mergeMessageBelowStateCommit(Directory dir) async {
    final result = await Process.run('git', [
      'log',
      '-2',
      '--format=%s',
      'main',
    ], workingDirectory: dir.path);
    final lines = (result.stdout as String).trim().split('\n');
    return lines.first == '#gg: Add .gg/gg.json check results'
        ? lines.last
        : lines.first;
  }

  // Builds the DoConfigurePublish that »do publish« runs when it is started
  // without a resolved configuration. Uses the mocked version selector and
  // non-interactive prompts.
  DoConfigurePublish makeConfigurePublish({
    EditMessage? editMessage,
    ConfirmDeleteFeatureBranch? confirmDeleteFeatureBranch,
  }) => DoConfigurePublish(
    ggLog: ggLog,
    versionSelector: versionSelector,
    editMessage: editMessage ?? defaultEditMessage,
    confirmDeleteFeatureBranch:
        confirmDeleteFeatureBranch ?? defaultConfirmDeleteFeatureBranch,
  );

  // MergeFlow variant for the bare test repo.
  MergeFlow noPubGetMergeFlow() => MergeFlow(
    ggLog: ggLog,
    doMerge: gg_merge.DoMerge(
      ggLog: ggLog,
      localMerge: gg_merge.LocalMerge(ggLog: ggLog),
    ),
  );

  void mockPublishIsSuccessful({
    required bool success,
    required bool askBeforePublishing,
  }) =>
      when(
        () => publish.exec(
          directory: dMock(),
          ggLog: ggLog,
          askBeforePublishing: askBeforePublishing,
          targets: any(named: 'targets'),
          onPublished: any(named: 'onPublished'),
        ),
      ).thenAnswer((_) async {
        if (!success) {
          throw Exception(cDetail('Publishing failed.'));
        } else {
          publishedVersionValue = Version.parse('1.2.4');
          ggLog('Publishing was successful.');
        }
      });

  void mockPublishedVersion() {
    when(
      () => publishedVersion.get(
        directory: dMock(),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {
      return publishedVersionValue;
    });

    // The registry safety net asks per registry, so the repo's single target
    // has to answer the same version.
    when(
      () => publishedVersion.latestVersionFor(
        target: any(named: 'target'),
        directory: dMock(),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {
      return publishedVersionValue;
    });
  }

  void mockVersionSelector() =>
      when(
        () => versionSelector.selectIncrement(
          currentVersion: any(named: 'currentVersion'),
        ),
      ).thenAnswer((_) async {
        return VersionIncrement.patch;
      });

  // Runs a full single-repo publish on the rc channel and asserts pubspec.yaml
  // ends up at the next rc prerelease. [useCliFlag] chooses between the
  // `--channel rc` CLI flag and a `channel: rc` field in the --config file.
  Future<void> runRcChannelTest({required bool useCliFlag}) async {
    mockPublishIsSuccessful(success: true, askBeforePublishing: false);
    when(
      () => publishedVersion.allVersions(
        directory: dMock(),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async => [Version.parse('1.2.3')]);

    final cfgDir = await Directory.systemTemp.createTemp('publish_config_');
    final cfgPath = join(cfgDir.path, 'release.json');
    await File(cfgPath).writeAsString(
      '{"version_increment":"patch", "merge_message":"rc release"'
      '${useCliFlag ? '' : ', "channel":"rc"'}, '
      '"delete_feature_branch":false}',
    );

    final cliDoPublish = DoPublish(
      upgradeDeps: upgradeDeps,
      waitUntilPublished: waitUntilPublished,
      ggLog: ggLog,
      publish: publish,
      prepareNextVersion: PrepareNextVersion(
        ggLog: ggLog,
        publishedVersion: publishedVersion,
      ),
      canPublish: canPublish,
      configurePublish: makeConfigurePublish(),
      publishedVersion: publishedVersion,
      processWrapper: processWrapper,
      localBranch: localBranch,
      confirmDeleteFeatureBranch: (_) async => false,
      mergeFlow: noPubGetMergeFlow(),
    );

    final runner = CommandRunner<void>('gg', 'gg')..addCommand(cliDoPublish);

    await runner.run(<String>[
      'publish',
      '-i',
      d.path,
      '--config',
      cfgPath,
      if (useCliFlag) ...['--channel', 'rc'],
      '--no-ask-before-publishing',
    ]);

    final pubspec = await File(join(d.path, 'pubspec.yaml')).readAsString();
    expect(pubspec, contains('version: 1.2.4-rc.1'));

    cfgDir.deleteSync(recursive: true);
  }

  // ...........................................................................
  // The setUp fixture is a copy of the same template in every test, so its
  // LastChangesHash is identical too - compute it only once per test file.
  int? freshFixtureHash;

  // ...........................................................................
  Future<void> makeLastStateSuccessful({bool isFreshFixture = false}) async {
    if (isFreshFixture && freshFixtureHash != null) {
      successHash = freshFixtureHash!;
    } else {
      successHash = await LastChangesHash(ggLog: ggLog)
          .get(directory: d, ggLog: ggLog, ignoreFiles: GgState.ignoreFiles);
      if (isFreshFixture) {
        freshFixtureHash = successHash;
      }
    }

    final ggDir = Directory(join(d.path, '.gg'));
    if (!ggDir.existsSync()) {
      await ggDir.create(recursive: true);
    }

    await File(join(ggDir.path, 'gg.json')).writeAsString(
      '{"canCommit":{"success":{"hash":$successHash}},'
      '"doCommit":{"success":{"hash":$successHash}},'
      '"canPush":{"success":{"hash":$successHash}},'
      '"doPush":{"success":{"hash":$successHash}},'
      '"canPublish":{"success":{"hash":$successHash}}}',
    );
  }

  // ...........................................................................
  Future<void> resetTicketFile() async {
    await File(join(d.path, 'ticket.json')).writeAsString(
      jsonEncode(<String, String>{
        'issue_id': 'feat_abc',
        'description': 'Ticket merge message',
      }),
    );
  }

  // ...........................................................................
  setUp(() async {
    // Create repositories from a template that is built only once per
    // test file and copied for every test.
    (d, dRemote) = await initCachedRepoPair(
      key: 'do_publish_base',
      build: (local, remote) async {
        await initLocalGit(local);
        await enableEolLf(local);
        await initRemoteGit(remote);
        await addRemoteToLocal(local: local, remote: remote);

        // Setup a pubspec.yaml and a CHANGELOG.md with right versions.
        // The SDK constraint is not decoration: `can push` runs `pub get
        // --offline` before `isCommitted`, and pub refuses a manifest
        // without a lower bound.
        await File(join(local.path, 'pubspec.yaml')).writeAsString(
          'name: gg\n\nversion: 1.2.3\n'
          'environment:\n  sdk: ^3.8.0\n'
          'repository: https://github.com/inlavigo/gg.git',
        );

        // Prepare ChangeLog
        await File(join(local.path, 'CHANGELOG.md')).writeAsString(
          '# Changelog\n\n'
          '## Unreleased\n'
          '-Message 1\n'
          '-Message 2\n'
          '## 1.2.3 - 2024-04-05\n\n- First version',
        );

        await addAndCommitSampleFile(
          local,
          fileName: 'CLAUDE.md',
          content: 'This is the CLAUDE.md',
        );
        final runner = CommandRunner<void>('gg', 'gg')
          ..addCommand(CreateTicket(ggLog: ggLog));
        await runner.run([
          'ticket',
          '-i',
          local.path,
          'feat_abc',
          '-m',
          'Ticket merge message',
        ]);
        await commitFile(local, 'CLAUDE.md');
        await addAndCommitSampleFile(
          local,
          fileName: 'README.md',
          content: 'This is the readme',
        );
        await pushLocalChangesUpstream(local, 'feat_abc');
      },
    );
    publishedVersionValue = Version.parse('1.2.3');

    // Clear messages
    messages.clear();

    // Create a .gg/gg.json that has all preconditions for publishing
    needsChangeHash = 12345;

    // Mock publishing
    dMock = () => any(
      named: 'directory',
      that: predicate<Directory>((x) => x.path == d.path),
    );
    registerFallbackValue(d);
    registerFallbackValue(Version(0, 0, 0));
    registerFallbackValue(PublishTarget.pubDev);
    publish = MockPublish();
    waitUntilPublished = MockWaitUntilPublished();
    upgradeDeps = MockDoUpgradeDeps();
    upgradeDeps.mockExec(result: null);
    when(
      () => waitUntilPublished.get(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {});
    processWrapper = MockGgProcessWrapper();
    localBranch = MockLocalBranch();

    // The publish switches between the feature and the default branch, and
    // the checkout helpers consult LocalBranch for where HEAD currently is —
    // a fixed answer would make them skip or repeat checkouts. The mock
    // therefore reports the real repository; tests that need a fixed branch
    // override it.
    when(
      () => localBranch.get(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {
      final result = await Process.run('git', [
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ], workingDirectory: d.path);
      return (result.stdout as String).trim();
    });

    // The branch switches and the bare-ref push of the default branch run
    // through the injectable process wrapper. Delegate them to the real
    // repository by default, so the integration tests actually change
    // branches and push; tests that assert the behavior itself override
    // these stubs with fakes.
    for (final branch in ['main', 'master']) {
      when(
        () => processWrapper.run('git', [
          'push',
          'origin',
          branch,
        ], workingDirectory: d.path),
      ).thenAnswer(
        (_) => Process.run('git', [
          'push',
          'origin',
          branch,
        ], workingDirectory: d.path),
      );
    }
    for (final branch in ['main', 'master', 'feat_abc', 'feat_other']) {
      when(
        () => processWrapper.run('git', [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/$branch',
        ], workingDirectory: d.path),
      ).thenAnswer(
        (_) => Process.run('git', [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/$branch',
        ], workingDirectory: d.path),
      );
      when(
        () => processWrapper.run('git', [
          'checkout',
          branch,
        ], workingDirectory: d.path),
      ).thenAnswer(
        (_) =>
            Process.run('git', ['checkout', branch], workingDirectory: d.path),
      );
    }

    // The delete step looks the remote ref up first. By default both branches
    // used in the tests still exist on the remote.
    for (final branch in ['feat_abc', 'feat_other']) {
      when(
        () => processWrapper.run('git', [
          'ls-remote',
          '--heads',
          'origin',
          branch,
        ], workingDirectory: d.path),
      ).thenAnswer(
        (_) async => ProcessResult(0, 0, 'abc123\trefs/heads/$branch\n', ''),
      );
    }

    when(
      () => processWrapper.run('git', [
        'push',
        'origin',
        '--delete',
        'feat_abc',
      ], workingDirectory: d.path),
    ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

    // A hybrid has one lock file per ecosystem, so both are looked at.
    for (final lockFile in <String>[
      'pubspec.lock',
      'package-lock.json',
      'pnpm-lock.yaml',
      'yarn.lock',
    ]) {
      when(
        () => processWrapper.run('git', [
          'status',
          '--porcelain',
          lockFile,
        ], workingDirectory: d.path),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
    }

    // Default: a remote without pull-request support → local merge flow.
    when(
      () => processWrapper.run(
        'git',
        ['config', '--get', 'remote.origin.url'],
        runInShell: true,
        workingDirectory: d.path,
      ),
    ).thenAnswer(
      (_) async =>
          ProcessResult(0, 0, 'https://git.example.com/inlavigo/gg.git', ''),
    );

    publishedVersion = MockPublishedVersion();

    canPublish = CanPublish(ggLog: ggLog);
    mockPublishedVersion();

    versionSelector = MockVersionSelector();
    mockVersionSelector();

    // Instantiate with mocks
    doPublish = DoPublish(
      upgradeDeps: upgradeDeps,
      waitUntilPublished: waitUntilPublished,
      ggLog: ggLog,
      publish: publish,
      prepareNextVersion: PrepareNextVersion(
        ggLog: ggLog,
        publishedVersion: publishedVersion,
      ),
      canPublish: canPublish,
      configurePublish: makeConfigurePublish(),
      publishedVersion: publishedVersion,
      processWrapper: processWrapper,
      localBranch: localBranch,
      confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
      mergeFlow: noPubGetMergeFlow(),
    );

    await makeLastStateSuccessful(isFreshFixture: true);
    messages.clear();
  });

  tearDown(() async {
    await d.delete(recursive: true);
    await dRemote.delete(recursive: true);
  });

  group('DoPublish', () {
    group('exec(directory)', () {
      group('should succeed', () {
        group('and publish', () {
          group('to pub.dev', () {
            group('when no »publish_to: none« is found in pubspec.yaml', () {
              group('when the package', () {
                group('has been published before', () {
                  group('and ask for confirmation', () {
                    for (final ask in [true, null]) {
                      test('when askBeforePublishing is $ask', () async {
                        // Expect asking for confirmation
                        mockPublishIsSuccessful(
                          success: true,
                          askBeforePublishing: true,
                        );
                        publishedVersionValue = Version(1, 2, 3);
                        mockPublishedVersion();

                        messages.clear();

                        // Publish
                        await doPublish.exec(
                          directory: d,
                          ggLog: ggLog,
                          askBeforePublishing: ask,
                          deleteFeatureBranch: false,
                        );

                        final allMessages = messages.join('\n');
                        expect(allMessages, contains('Can publish?'));
                        expect(allMessages, contains('✓ Can publish?'));
                        expect(allMessages, contains('⌛️ Increase version'));
                        expect(allMessages, contains('✓ Increase version'));
                        expect(
                          allMessages,
                          contains('Publishing was successful.'),
                        );
                        expect(allMessages, contains('✓ Tag 1.2.4 added.'));

                        // Was a new version created?
                        final pubspec = await File(join(d.path, 'pubspec.yaml'))
                            .readAsString();
                        final changeLog = await File(
                          join(d.path, 'CHANGELOG.md'),
                        ).readAsString();
                        expect(pubspec, contains('version: 1.2.4'));
                        expect(changeLog, contains('## 1.2.4 -'));

                        // Was the new version checked in?
                        final headMessage = await mergeMessageBelowStateCommit(
                          d,
                        );
                        expect(headMessage, 'Ticket merge message');

                        // Did .gg/gg.json mark commit, push and publish done?
                        expect(
                          await DidCommit(ggLog: ggLog)
                              .get(directory: d, ggLog: ggLog),
                          isTrue,
                        );

                        expect(
                          await DidPush(ggLog: ggLog)
                              .get(directory: d, ggLog: ggLog),
                          isTrue,
                        );

                        // »gg did publish« reads the tags now.
                        final why = <String>[];
                        expect(
                          await DidPublish(ggLog: why.add)
                              .get(directory: d, ggLog: why.add),
                          isTrue,
                          reason: why.join('\n'),
                        );

                        // Did the publish wait for the version to become
                        // visible on the registry?
                        verify(
                          () => waitUntilPublished.get(
                            directory: any(named: 'directory'),
                            ggLog: any(named: 'ggLog'),
                          ),
                        ).called(1);
                      });
                    }
                  });

                  group('has not been published before', () {
                    test('and publishes without asking', () async {
                      // A package that is not on its registry yet is
                      // published like any other. The former refusal pointed
                      // at »gg do push --ask-before-publishing«, an option
                      // that command does not have.
                      publishedVersionValue = Version(0, 0, 0);
                      mockPublishedVersion();
                      when(
                        () => publishedVersion.latestVersionFor(
                          target: any(named: 'target'),
                          directory: dMock(),
                          ggLog: any(named: 'ggLog'),
                        ),
                      ).thenAnswer((_) async => null);

                      // Expect not asking for confirmation
                      mockPublishIsSuccessful(
                        success: true,
                        askBeforePublishing: false,
                      );

                      // Publish
                      await doPublish.exec(
                        directory: d,
                        ggLog: ggLog,
                        askBeforePublishing: false,
                        deleteFeatureBranch: false,
                      );
                    });

                    test('and askForConfirmation is true', () async {
                      // Mock that the package was never published before
                      publishedVersionValue = Version(0, 0, 0);
                      mockPublishedVersion();

                      // Expect asking for confirmation
                      mockPublishIsSuccessful(
                        success: true,
                        askBeforePublishing: true,
                      );

                      // Publish
                      await doPublish.exec(
                        directory: d,
                        ggLog: ggLog,
                        askBeforePublishing: true,
                        deleteFeatureBranch: false,
                      );

                      // Check
                    });
                  });
                });
              });

              group('without asking for confirmation', () {
                test('when askBeforePublishing is false', () async {
                  // Expect not asking for confirmation
                  mockPublishIsSuccessful(
                    success: true,
                    askBeforePublishing: false,
                  );

                  // Publish
                  await doPublish.exec(
                    directory: d,
                    ggLog: ggLog,
                    askBeforePublishing: false,
                    deleteFeatureBranch: false,
                  );

                  // Check result
                });
              });
            });
          });

          test('commits pubspec.lock if modified during publishing', () async {
            when(
              () => publish.exec(
                directory: dMock(),
                ggLog: ggLog,
                askBeforePublishing: false,
                targets: any(named: 'targets'),
                onPublished: any(named: 'onPublished'),
              ),
            ).thenAnswer((_) async {
              await File(join(d.path, 'pubspec.lock'))
                  .writeAsString('packages: {}\n');
              publishedVersionValue = Version.parse('1.2.4');
            });

            when(
              () => processWrapper.run('git', [
                'status',
                '--porcelain',
                'pubspec.lock',
              ], workingDirectory: d.path),
            ).thenAnswer(
              (_) async => ProcessResult(0, 0, ' M pubspec.lock', ''),
            );

            await doPublish.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
              deleteFeatureBranch: false,
            );

            expect(
              await DidCommit(ggLog: ggLog).get(directory: d, ggLog: ggLog),
              isTrue,
            );
          });

          test('writes the doPush state for the release commit '
              'and pushes the version tag', () async {
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);

            // The doPush state carries a stale hash from development — as on
            // a real feature branch, where the last »gg do push« ran before
            // the release commits existed. Without a fresh doPush state on
            // the release commit, »gg did push« fails on a CI checkout.
            await DirectJson.writeFile(
              file: File(join(d.path, '.gg', 'gg.json')),
              path: 'doPush/success/hash',
              value: needsChangeHash,
            );

            await doPublish.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
              deleteFeatureBranch: false,
            );

            // The fresh doPush state matters for the release commit on the
            // default branch — a CI checkout of the released package reads
            // it there. HEAD ends up back on the feature branch, so switch
            // over to assert it.
            await Process.run('git', [
              'checkout',
              'main',
            ], workingDirectory: d.path);
            expect(
              await DidPush(ggLog: ggLog).get(directory: d, ggLog: ggLog),
              isTrue,
            );

            // The version tag must arrive on the remote.
            final remoteTags = await Process.run('git', [
              'tag',
            ], workingDirectory: dRemote.path);
            expect(remoteTags.stdout, contains('1.2.4'));
          });

          group('not to pub.dev', () {
            test('when »publish_to: none« in pubspec.yaml', () async {
              doPublish = DoPublish(
                upgradeDeps: upgradeDeps,
                waitUntilPublished: waitUntilPublished,
                ggLog: ggLog,
                publish: publish,
                configurePublish: makeConfigurePublish(),
                processWrapper: processWrapper,
                localBranch: localBranch,
                confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
                mergeFlow: noPubGetMergeFlow(),
              );

              // Prepare pubspec.yaml
              final pubspecFile = File(join(d.path, 'pubspec.yaml'));
              const currentVersion = '1.0.1';
              await addAndCommitVersions(
                d,
                pubspec: currentVersion,
                changeLog: 'Unreleased',
                gitHead: currentVersion,
                appendToPubspec: '\npublish_to: none',
              );
              var pubspec = await pubspecFile.readAsString();
              expect(pubspec, contains('version: 1.0.1'));

              await makeLastStateSuccessful();

              messages.clear();

              // Publish
              await doPublish.exec(
                directory: d,
                ggLog: ggLog,
                deleteFeatureBranch: false,
              );

              final allMessages = messages.join('\n');
              expect(allMessages, contains('Can publish?'));
              expect(allMessages, contains('✓ Can publish?'));
              expect(allMessages, contains('⌛️ Increase version'));
              expect(allMessages, contains('✓ Increase version'));
              expect(allMessages, contains('Tag 1.0.2 added.'));

              // Skipping the registry is announced, never silent.
              expect(allMessages, contains('Not publishing to a registry'));

              // Was a new version created?
              pubspec = await pubspecFile.readAsString();
              final changeLog = await File(join(d.path, 'CHANGELOG.md'))
                  .readAsString();
              expect(pubspec, contains('version: 1.0.2'));
              expect(changeLog, contains('## 1.0.2 -'));

              // Was the new version checked in?
              final headMessage = await mergeMessageBelowStateCommit(d);
              expect(headMessage, 'Ticket merge message');

              // Did .gg/gg.json mark commit, push and publish done?
              expect(
                await DidCommit(ggLog: ggLog).get(directory: d, ggLog: ggLog),
                isTrue,
              );

              expect(
                await DidPush(ggLog: ggLog).get(directory: d, ggLog: ggLog),
                isTrue,
              );
            });
          });

          group('refuses to publish a ticket repo whose publish target '
              'is suppressed', () {
            // »gg multi do add« writes »publish_to: none« into every ticket
            // repo and remembers the original value. Publishing such a repo
            // standalone would skip the registry upload and merge the
            // suppressed manifest into main.
            Future<void> writeBackup(
              String content, {
              bool hidden = false,
            }) async {
              final ggDir = Directory(join(d.path, '.gg'));
              if (!ggDir.existsSync()) {
                await ggDir.create(recursive: true);
              }
              const name = 'gg_localize_refs_publish_to_backup.json';
              await File(join(ggDir.path, hidden ? '.$name' : name))
                  .writeAsString(content);
            }

            test('and points to "gg multi do publish"', () async {
              await writeBackup('{"publish_to_original": null}');

              await expectLater(
                doPublish.exec(
                  directory: d,
                  ggLog: ggLog,
                  deleteFeatureBranch: false,
                ),
                throwsA(
                  isA<Exception>().having(
                    (e) => rmControls(e.toString()),
                    'message',
                    allOf(
                      contains('ticket workspace'),
                      contains('gg multi do publish'),
                    ),
                  ),
                ),
              );
            });

            test(
              'also when the backup still carries the hidden name',
              () async {
                // A ticket repo checked out before the files inside .gg were
                // unhidden must not slip past the guard.
                await writeBackup(
                  '{"publish_to_original": null}',
                  hidden: true,
                );

                await expectLater(
                  doPublish.exec(
                    directory: d,
                    ggLog: ggLog,
                    deleteFeatureBranch: false,
                  ),
                  throwsA(
                    isA<Exception>().having(
                      (e) => rmControls(e.toString()),
                      'message',
                      contains('gg multi do publish'),
                    ),
                  ),
                );
              },
            );

            test('but publishes a genuinely private package', () async {
              // A package that publishes nowhere outside the ticket either
              // may be published (i.e. version-bumped + merged) as before.
              await writeBackup('{"publish_to_original": "none"}');
              // The new file changed the worktree — re-record the state so
              // the publish checks see a committed repository again.
              await makeLastStateSuccessful();
              mockPublishIsSuccessful(success: true, askBeforePublishing: true);

              await doPublish.exec(
                directory: d,
                ggLog: ggLog,
                deleteFeatureBranch: false,
              );

              expect(messages.join('\n'), contains('Tag 1.2.4 added.'));
            });
          });

          group('refuses when the next version is already in '
              'CHANGELOG.md', () {
            // The published version is 1.2.3 and the increment is patch,
            // i.e. the next version is 1.2.4.
            Future<void> writeAndCommitChangelog(String content) async {
              await File(join(d.path, 'CHANGELOG.md')).writeAsString(content);
              await commitFile(d, 'CHANGELOG.md', message: 'Update CHANGELOG');
            }

            Future<void> writeAndCommitPubspec(String version) async {
              await File(join(d.path, 'pubspec.yaml')).writeAsString(
                'name: gg\n\nversion: $version\n'
                'environment:\n  sdk: ^3.8.0\n'
                'repository: https://github.com/inlavigo/gg.git',
              );
              await commitFile(d, 'pubspec.yaml', message: 'Update pubspec');
            }

            final throwsAlreadyInChangelog = throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('CHANGELOG.md already contains the version »1.2.4«'),
              ),
            );

            test('and »## Unreleased« entries would get lost', () async {
              await writeAndCommitPubspec('1.2.4');
              await writeAndCommitChangelog(
                '# Changelog\n\n'
                '## Unreleased\n\n'
                '### Added\n\n'
                '- Pending change\n\n'
                '## 1.2.4 - 2024-04-09\n\n'
                '### Changed\n\n'
                '- Merged too early\n\n'
                '## 1.2.3 - 2024-04-05\n\n'
                '- First version\n',
              );
              await makeLastStateSuccessful();
              messages.clear();

              await expectLater(
                doPublish.exec(
                  directory: d,
                  ggLog: ggLog,
                  deleteFeatureBranch: false,
                ),
                throwsAlreadyInChangelog,
              );

              final allMessages = messages.join('\n');
              expect(
                allMessages,
                contains(
                  'The next version »1.2.4« is already in ./CHANGELOG.md',
                ),
              );
              expect(
                allMessages,
                contains(
                  'would lose the entries still sitting in »## Unreleased«',
                ),
              );
              expect(allMessages, isNot(contains('does not match')));
              expect(allMessages, contains('Please fix ./CHANGELOG.md'));

              // Nothing was published
              verifyNever(
                () => publish.exec(
                  directory: any(named: 'directory'),
                  ggLog: any(named: 'ggLog'),
                  askBeforePublishing: any(named: 'askBeforePublishing'),
                  targets: any(named: 'targets'),
                  onPublished: any(named: 'onPublished'),
                ),
              );
            });

            test('and the pubspec.yaml version does not match', () async {
              await writeAndCommitChangelog(
                '# Changelog\n\n'
                '## 1.2.4 - 2024-04-09\n\n'
                '### Changed\n\n'
                '- Merged too early\n\n'
                '## 1.2.3 - 2024-04-05\n\n'
                '- First version\n',
              );
              await makeLastStateSuccessful();
              messages.clear();

              await expectLater(
                doPublish.exec(
                  directory: d,
                  ggLog: ggLog,
                  deleteFeatureBranch: false,
                ),
                throwsAlreadyInChangelog,
              );

              final allMessages = messages.join('\n');
              expect(
                allMessages,
                contains(
                  'the version in ./pubspec.yaml (»1.2.3«) does not match '
                  '»1.2.4«',
                ),
              );
              expect(allMessages, isNot(contains('would lose the entries')));

              // The pubspec.yaml was not touched
              final pubspec = await File(join(d.path, 'pubspec.yaml'))
                  .readAsString();
              expect(pubspec, contains('version: 1.2.3'));
            });

            test('and reports both problems when both occur', () async {
              await writeAndCommitChangelog(
                '# Changelog\n\n'
                '## Unreleased\n\n'
                '### Added\n\n'
                '- Pending change\n\n'
                '## 1.2.4 - 2024-04-09\n\n'
                '### Changed\n\n'
                '- Merged too early\n\n'
                '## 1.2.3 - 2024-04-05\n\n'
                '- First version\n',
              );
              await makeLastStateSuccessful();
              messages.clear();

              await expectLater(
                doPublish.exec(
                  directory: d,
                  ggLog: ggLog,
                  deleteFeatureBranch: false,
                ),
                throwsAlreadyInChangelog,
              );

              final allMessages = messages.join('\n');
              expect(allMessages, contains('would lose the entries'));
              expect(allMessages, contains('does not match'));
            });

            test('but continues and sorts the changelog when the state is '
                'a fully prepared resume state', () async {
              // A previous run bumped the version and released the
              // changelog, but died before the upload. pubspec.yaml carries
              // the next version and no unreleased entries exist — but a
              // merge left the versions in the wrong order.
              mockPublishIsSuccessful(success: true, askBeforePublishing: true);
              await writeAndCommitPubspec('1.2.4');
              await writeAndCommitChangelog(
                '# Changelog\n\n'
                '## 1.2.3 - 2024-04-05\n\n'
                '- First version\n\n'
                '## 1.2.4 - 2024-04-09\n\n'
                '### Changed\n\n'
                '- Something new\n',
              );
              await makeLastStateSuccessful();
              messages.clear();

              await doPublish.exec(
                directory: d,
                ggLog: ggLog,
                deleteFeatureBranch: false,
              );

              final allMessages = messages.join('\n');
              expect(allMessages, isNot(contains('already contains')));
              expect(allMessages, contains('Publishing was successful.'));
              expect(allMessages, contains('Tag 1.2.4 added.'));

              // The changelog was sorted. Newest version first.
              final changeLog = await File(join(d.path, 'CHANGELOG.md'))
                  .readAsString();
              expect(
                changeLog.indexOf('## 1.2.4'),
                lessThan(changeLog.indexOf('## 1.2.3')),
              );
              expect('## 1.2.4'.allMatches(changeLog).length, 1);
            });
          });

          test('passes a custom merge message '
              'to the final merge step', () async {
            const customMessage = 'My custom merge message';

            mockPublishIsSuccessful(success: true, askBeforePublishing: false);

            await doPublish.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
              message: customMessage,
              deleteFeatureBranch: false,
            );

            final headMessage = await mergeMessageBelowStateCommit(d);
            expect(headMessage, customMessage);
          });

          test('loads merge message from ticket.json '
              'and allows editing when not provided', () async {
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);

            await File(join(d.path, 'ticket.json')).writeAsString(
              jsonEncode(<String, String>{
                'issue_id': 'feat_abc',
                'description': 'Ticket merge message',
              }),
            );

            var initialMessage = '';
            final doPublishWithEditor = DoPublish(
              upgradeDeps: upgradeDeps,
              waitUntilPublished: waitUntilPublished,
              ggLog: ggLog,
              publish: publish,
              prepareNextVersion: PrepareNextVersion(
                ggLog: ggLog,
                publishedVersion: publishedVersion,
              ),
              canPublish: canPublish,
              configurePublish: makeConfigurePublish(
                editMessage: (String message) async {
                  initialMessage = message;
                  return 'Edited merge message';
                },
              ),
              publishedVersion: publishedVersion,
              processWrapper: processWrapper,
              localBranch: localBranch,
              confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
              mergeFlow: noPubGetMergeFlow(),
            );

            await doPublishWithEditor.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
              deleteFeatureBranch: false,
            );

            expect(initialMessage, 'Ticket merge message');

            final headMessage = await mergeMessageBelowStateCommit(d);
            expect(headMessage, 'Edited merge message');
          });

          test('uses empty initial merge message when '
              'ticket.json is missing and message is not provided', () async {
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);
            final ticketFile = File(join(d.path, 'ticket.json'));
            if (await ticketFile.exists()) {
              await ticketFile.delete();
            }

            // commit deletion and refresh state hashes
            await commitFile(d, 'ticket.json');
            await makeLastStateSuccessful();

            var initialMessage = 'not set';
            final doPublishWithEditor = DoPublish(
              upgradeDeps: upgradeDeps,
              waitUntilPublished: waitUntilPublished,
              ggLog: ggLog,
              publish: publish,
              prepareNextVersion: PrepareNextVersion(
                ggLog: ggLog,
                publishedVersion: publishedVersion,
              ),
              canPublish: canPublish,
              configurePublish: makeConfigurePublish(
                editMessage: (String message) async {
                  initialMessage = message;
                  return 'Edited without ticket';
                },
              ),
              publishedVersion: publishedVersion,
              processWrapper: processWrapper,
              localBranch: localBranch,
              confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
              mergeFlow: noPubGetMergeFlow(),
            );

            await doPublishWithEditor.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
              deleteFeatureBranch: false,
            );

            expect(initialMessage, '');

            final headMessage = await mergeMessageBelowStateCommit(d);
            expect(headMessage, 'Edited without ticket');
          });

          test('does not open editor when merge '
              'message is provided programmatically', () async {
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);

            await File(join(d.path, 'ticket.json')).writeAsString(
              jsonEncode(<String, String>{
                'issue_id': 'feat_abc',
                'description': 'Ticket merge message',
              }),
            );

            final doPublishWithEditor = DoPublish(
              upgradeDeps: upgradeDeps,
              waitUntilPublished: waitUntilPublished,
              ggLog: ggLog,
              publish: publish,
              prepareNextVersion: PrepareNextVersion(
                ggLog: ggLog,
                publishedVersion: publishedVersion,
              ),
              canPublish: canPublish,
              configurePublish: makeConfigurePublish(
                editMessage: (_) async {
                  fail('Editor must not be opened when message is provided.');
                },
              ),
              publishedVersion: publishedVersion,
              processWrapper: processWrapper,
              localBranch: localBranch,
              confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
              mergeFlow: noPubGetMergeFlow(),
            );

            await doPublishWithEditor.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
              message: 'Programmatic merge message',
              deleteFeatureBranch: false,
            );

            final headMessage = await mergeMessageBelowStateCommit(d);
            expect(headMessage, 'Programmatic merge message');
          });

          test(
            'deletes the feature branch when requested explicitly',
            () async {
              mockPublishIsSuccessful(
                success: true,
                askBeforePublishing: false,
              );

              await doPublish.exec(
                directory: d,
                ggLog: ggLog,
                askBeforePublishing: false,
                deleteFeatureBranch: true,
              );

              verify(
                () => processWrapper.run('git', [
                  'push',
                  'origin',
                  '--delete',
                  'feat_abc',
                ], workingDirectory: d.path),
              ).called(1);
              expect(
                messages.last,
                contains('Deleted remote feature branch feat_abc.'),
              );
            },
          );

          test('backs up a leftover pubspec_overrides.yaml for the release '
              'and restores it at the end', () async {
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);

            final overrides = File(join(d.path, 'pubspec_overrides.yaml'))
              ..writeAsStringSync(
                'dependency_overrides:\n  gg_log:\n    path: ../gg_log',
              );

            await doPublish.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
              deleteFeatureBranch: false,
            );

            // The publish removed the file up front, so the release
            // resolved against the registry instead of the developer's
            // working copies ...
            expect(
              messages.join('\n'),
              contains(
                'Saved pubspec_overrides.yaml to '
                '$pubspecOverridesBackupPath and deleted it.',
              ),
            );

            // ... and restored it once the feature branch was checked out
            // again, so the repository keeps resolving against the
            // sibling checkouts of its ticket workspace. The restore
            // consumes the backup.
            expect(
              overrides.readAsStringSync(),
              'dependency_overrides:\n  gg_log:\n    path: ../gg_log',
            );
            expect(
              File(join(d.path, pubspecOverridesBackupPath)).existsSync(),
              isFalse,
            );
            expect(
              messages.join('\n'),
              contains(
                'Restored pubspec_overrides.yaml from '
                '$pubspecOverridesBackupPath.',
              ),
            );

            // The restored overrides are part of the working tree again —
            // the didPublish state was re-recorded for exactly this
            // content, so »gg did publish« keeps answering yes.
            expect(
              await DidPublish(ggLog: ggLog).get(directory: d, ggLog: ggLog),
              isTrue,
            );
          });

          test(
            'skips the delete when the remote branch is already gone',
            () async {
              mockPublishIsSuccessful(
                success: true,
                askBeforePublishing: false,
              );

              // E.g. the provider deleted the source branch when it merged
              // the pull request.
              when(
                () => processWrapper.run('git', [
                  'ls-remote',
                  '--heads',
                  'origin',
                  'feat_abc',
                ], workingDirectory: d.path),
              ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

              await doPublish.exec(
                directory: d,
                ggLog: ggLog,
                askBeforePublishing: false,
                deleteFeatureBranch: true,
              );

              verifyNever(
                () => processWrapper.run('git', [
                  'push',
                  'origin',
                  '--delete',
                  'feat_abc',
                ], workingDirectory: d.path),
              );
              expect(
                messages.join('\n'),
                isNot(contains('feature branch feat_abc')),
              );
            },
          );

          test(
            'deletes the feature branch when the remote lookup fails',
            () async {
              mockPublishIsSuccessful(
                success: true,
                askBeforePublishing: false,
              );

              // A failing lookup (no network, no remote) must not silently skip
              // the deletion — the delete itself reports the real error.
              when(
                () => processWrapper.run('git', [
                  'ls-remote',
                  '--heads',
                  'origin',
                  'feat_abc',
                ], workingDirectory: d.path),
              ).thenAnswer((_) async => ProcessResult(0, 128, '', 'no remote'));

              await doPublish.exec(
                directory: d,
                ggLog: ggLog,
                askBeforePublishing: false,
                deleteFeatureBranch: true,
              );

              verify(
                () => processWrapper.run('git', [
                  'push',
                  'origin',
                  '--delete',
                  'feat_abc',
                ], workingDirectory: d.path),
              ).called(1);
            },
          );

          test(
            'does not delete the feature branch when disabled explicitly',
            () async {
              mockPublishIsSuccessful(
                success: true,
                askBeforePublishing: false,
              );

              await doPublish.exec(
                directory: d,
                ggLog: ggLog,
                askBeforePublishing: false,
                deleteFeatureBranch: false,
              );

              verifyNever(
                () => processWrapper.run('git', [
                  'push',
                  'origin',
                  '--delete',
                  'feat_abc',
                ], workingDirectory: d.path),
              );
            },
          );

          test('asks whether to delete the feature branch when not specified — '
              'up front, inside configure-publish', () async {
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);

            var promptBranchName = '';
            final doPublishWithPrompt = DoPublish(
              upgradeDeps: upgradeDeps,
              waitUntilPublished: waitUntilPublished,
              ggLog: ggLog,
              publish: publish,
              prepareNextVersion: PrepareNextVersion(
                ggLog: ggLog,
                publishedVersion: publishedVersion,
              ),
              canPublish: canPublish,
              // The decision is asked by configure-publish — before the
              // publish pipeline starts, never between its steps.
              configurePublish: makeConfigurePublish(
                confirmDeleteFeatureBranch: (branchName) async {
                  promptBranchName = branchName;
                  return true;
                },
              ),
              publishedVersion: publishedVersion,
              processWrapper: processWrapper,
              localBranch: localBranch,
              confirmDeleteFeatureBranch: (_) async =>
                  fail('DoPublish itself must not prompt here.'),
              mergeFlow: noPubGetMergeFlow(),
            );

            await doPublishWithPrompt.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
            );

            expect(promptBranchName, 'feat_abc');
            verify(
              () => processWrapper.run('git', [
                'push',
                'origin',
                '--delete',
                'feat_abc',
              ], workingDirectory: d.path),
            ).called(1);
          });

          test(
            'asks up front when the config file lacks delete_feature_branch',
            () async {
              mockPublishIsSuccessful(
                success: true,
                askBeforePublishing: false,
              );
              // Config-only runtime file without the new field.
              File(join(d.path, '.gg', 'gg-publish.json')).writeAsStringSync(
                '{"version_increment":"patch","merge_message":"msg"}',
              );

              var promptBranchName = '';
              final doPublishWithPrompt = DoPublish(
                upgradeDeps: upgradeDeps,
                waitUntilPublished: waitUntilPublished,
                ggLog: ggLog,
                publish: publish,
                prepareNextVersion: PrepareNextVersion(
                  ggLog: ggLog,
                  publishedVersion: publishedVersion,
                ),
                canPublish: canPublish,
                configurePublish: makeConfigurePublish(
                  editMessage: (_) async =>
                      fail('Config exists — configure must not run.'),
                ),
                publishedVersion: publishedVersion,
                processWrapper: processWrapper,
                localBranch: localBranch,
                confirmDeleteFeatureBranch: (branchName) async {
                  promptBranchName = branchName;
                  return true;
                },
                mergeFlow: noPubGetMergeFlow(),
              );

              await doPublishWithPrompt.exec(
                directory: d,
                ggLog: ggLog,
                askBeforePublishing: false,
              );

              expect(promptBranchName, 'feat_abc');
              verify(
                () => processWrapper.run('git', [
                  'push',
                  'origin',
                  '--delete',
                  'feat_abc',
                ], workingDirectory: d.path),
              ).called(1);
            },
          );

          test('reads delete_feature_branch from the config file', () async {
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);
            File(join(d.path, '.gg', 'gg-publish.json')).writeAsStringSync(
              '{"version_increment":"patch","merge_message":"msg",'
              '"delete_feature_branch":true}',
            );

            final headlessPublish = DoPublish(
              upgradeDeps: upgradeDeps,
              waitUntilPublished: waitUntilPublished,
              ggLog: ggLog,
              publish: publish,
              prepareNextVersion: PrepareNextVersion(
                ggLog: ggLog,
                publishedVersion: publishedVersion,
              ),
              canPublish: canPublish,
              configurePublish: makeConfigurePublish(
                editMessage: (_) async =>
                    fail('Config exists — configure must not run.'),
              ),
              publishedVersion: publishedVersion,
              processWrapper: processWrapper,
              localBranch: localBranch,
              confirmDeleteFeatureBranch: (_) async =>
                  fail('The config decides — no prompt allowed.'),
              mergeFlow: noPubGetMergeFlow(),
            );

            await headlessPublish.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
            );

            verify(
              () => processWrapper.run('git', [
                'push',
                'origin',
                '--delete',
                'feat_abc',
              ], workingDirectory: d.path),
            ).called(1);
          });

          test('uses CLI delete-feature-branch flag when provided', () async {
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);

            final cliDoPublish = DoPublish(
              upgradeDeps: upgradeDeps,
              waitUntilPublished: waitUntilPublished,
              ggLog: ggLog,
              publish: publish,
              prepareNextVersion: PrepareNextVersion(
                ggLog: ggLog,
                publishedVersion: publishedVersion,
              ),
              canPublish: canPublish,
              configurePublish: makeConfigurePublish(),
              publishedVersion: publishedVersion,
              processWrapper: processWrapper,
              localBranch: localBranch,
              confirmDeleteFeatureBranch: (_) async {
                fail('Prompt must not be used when flag is provided.');
              },
              mergeFlow: noPubGetMergeFlow(),
            );

            final runner = CommandRunner<void>('gg', 'gg')
              ..addCommand(cliDoPublish);

            await runner.run([
              'publish',
              '-i',
              d.path,
              '--no-ask-before-publishing',
              '--delete-feature-branch',
            ]);

            verify(
              () => processWrapper.run('git', [
                'push',
                'origin',
                '--delete',
                'feat_abc',
              ], workingDirectory: d.path),
            ).called(1);
          });

          test('reads version_increment + merge_message from --config '
              'when neither is supplied on the CLI', () async {
            // Covers the single-repo `--config` resolve path.
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);

            // Config sits outside the repo to keep the working tree clean.
            final cfgDir = await Directory.systemTemp.createTemp(
              'publish_config_',
            );
            final cfgPath = join(cfgDir.path, 'release.json');
            await File(cfgPath).writeAsString(
              '{"version_increment":"patch", '
              '"merge_message":"from .gg-publish.json", '
              '"delete_feature_branch":false}',
            );

            // Editor must stay shut when --config supplies both fields.
            final cliDoPublish = DoPublish(
              upgradeDeps: upgradeDeps,
              waitUntilPublished: waitUntilPublished,
              ggLog: ggLog,
              publish: publish,
              prepareNextVersion: PrepareNextVersion(
                ggLog: ggLog,
                publishedVersion: publishedVersion,
              ),
              canPublish: canPublish,
              configurePublish: makeConfigurePublish(
                editMessage: (String initial) async {
                  fail(
                    'Editor must not be opened when --config supplies the '
                    'merge_message (got initialMessage="$initial").',
                  );
                },
              ),
              publishedVersion: publishedVersion,
              processWrapper: processWrapper,
              localBranch: localBranch,
              // delete_feature_branch comes from the --config file — no
              // prompt and no CLI flag needed.
              confirmDeleteFeatureBranch: (_) async =>
                  fail('The --config file decides — no prompt allowed.'),
              mergeFlow: noPubGetMergeFlow(),
            );

            final runner = CommandRunner<void>('gg', 'gg')
              ..addCommand(cliDoPublish);

            await runner.run(<String>[
              'publish',
              '-i',
              d.path,
              '--config',
              cfgPath,
              '--no-ask-before-publishing',
            ]);

            // Reaching here proves the load+resolve path ran successfully.

            cfgDir.deleteSync(recursive: true);
          });

          test('publishes an rc prerelease when --config sets channel: rc', () {
            return runRcChannelTest(useCliFlag: false);
          });

          test('publishes an rc prerelease via the --channel rc flag', () {
            return runRcChannelTest(useCliFlag: true);
          });

          test('logs each executed command when --verbose is set', () async {
            mockPublishIsSuccessful(success: true, askBeforePublishing: false);

            final cliDoPublish = DoPublish(
              upgradeDeps: upgradeDeps,
              waitUntilPublished: waitUntilPublished,
              ggLog: ggLog,
              publish: publish,
              prepareNextVersion: PrepareNextVersion(
                ggLog: ggLog,
                publishedVersion: publishedVersion,
              ),
              canPublish: canPublish,
              configurePublish: makeConfigurePublish(),
              publishedVersion: publishedVersion,
              processWrapper: processWrapper,
              localBranch: localBranch,
              confirmDeleteFeatureBranch: (_) async => false,
              mergeFlow: noPubGetMergeFlow(),
            );

            final runner = CommandRunner<void>('gg', 'gg')
              ..addCommand(cliDoPublish);

            await runner.run([
              'publish',
              '-i',
              d.path,
              '--no-ask-before-publishing',
              '--no-delete-feature-branch',
              '--verbose',
            ]);

            expect(
              messages,
              contains('\$ git status --porcelain pubspec.lock'),
            );
          });

          test(
            'uses CLI no-delete-feature-branch flag when provided',
            () async {
              mockPublishIsSuccessful(
                success: true,
                askBeforePublishing: false,
              );

              final cliDoPublish = DoPublish(
                upgradeDeps: upgradeDeps,
                waitUntilPublished: waitUntilPublished,
                ggLog: ggLog,
                publish: publish,
                prepareNextVersion: PrepareNextVersion(
                  ggLog: ggLog,
                  publishedVersion: publishedVersion,
                ),
                canPublish: canPublish,
                configurePublish: makeConfigurePublish(),
                publishedVersion: publishedVersion,
                processWrapper: processWrapper,
                localBranch: localBranch,
                confirmDeleteFeatureBranch: (_) async {
                  fail('Prompt must not be used when flag is provided.');
                },
                mergeFlow: noPubGetMergeFlow(),
              );

              final runner = CommandRunner<void>('gg', 'gg')
                ..addCommand(cliDoPublish);

              await runner.run([
                'publish',
                '-i',
                d.path,
                '--no-ask-before-publishing',
                '--no-delete-feature-branch',
              ]);

              verifyNever(
                () => processWrapper.run('git', [
                  'push',
                  'origin',
                  '--delete',
                  'feat_abc',
                ], workingDirectory: d.path),
              );
            },
          );

          test(
            'uses CLI message without opening editor when provided',
            () async {
              mockPublishIsSuccessful(
                success: true,
                askBeforePublishing: false,
              );

              await resetTicketFile();

              final cliDoPublish = DoPublish(
                upgradeDeps: upgradeDeps,
                waitUntilPublished: waitUntilPublished,
                ggLog: ggLog,
                publish: publish,
                prepareNextVersion: PrepareNextVersion(
                  ggLog: ggLog,
                  publishedVersion: publishedVersion,
                ),
                canPublish: canPublish,
                configurePublish: makeConfigurePublish(
                  editMessage: (_) async {
                    fail(
                      'Editor must not be opened when CLI message is provided.',
                    );
                  },
                ),
                publishedVersion: publishedVersion,
                processWrapper: processWrapper,
                localBranch: localBranch,
                confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
                mergeFlow: noPubGetMergeFlow(),
              );

              final runner = CommandRunner<void>('gg', 'gg')
                ..addCommand(cliDoPublish);

              await runner.run([
                'publish',
                '-i',
                d.path,
                '--no-ask-before-publishing',
                '--message',
                'CLI merge message',
                '--no-delete-feature-branch',
              ]);

              final headMessage = await mergeMessageBelowStateCommit(d);
              expect(headMessage, 'CLI merge message');
            },
          );
        });
      });

      group('and throw', () {
        test('when deleting the feature branch fails', () async {
          mockPublishIsSuccessful(success: true, askBeforePublishing: false);

          when(
            () => processWrapper.run('git', [
              'push',
              'origin',
              '--delete',
              'feat_abc',
            ], workingDirectory: d.path),
          ).thenAnswer((_) async => ProcessResult(0, 1, '', 'Some error'));

          late String exception;

          try {
            await doPublish.exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
              deleteFeatureBranch: true,
            );
          } catch (e) {
            exception = rmControls(e.toString());
          }

          expect(
            exception,
            'Exception: git push origin --delete feat_abc failed: Some error',
          );
        });
      });
    });

    group('on a TypeScript project', () {
      test(
        'tags HEAD via AddTypeScriptVersionTag instead of the CHANGELOG flow',
        () async {
          // Turn the Dart repo into a TypeScript one: drop pubspec.yaml and
          // CHANGELOG.md, add a versioned package.json and a tsconfig.json.
          await File(join(d.path, 'pubspec.yaml')).delete();
          final changelog = File(join(d.path, 'CHANGELOG.md'));
          if (changelog.existsSync()) {
            await changelog.delete();
          }
          await addAndCommitSampleFile(
            d,
            fileName: 'package.json',
            content: '{"name": "x", "version": "1.2.3"}',
          );
          await addAndCommitSampleFile(
            d,
            fileName: 'tsconfig.json',
            content: '{}',
          );

          // Recompute the success state for the new TypeScript working tree.
          await makeLastStateSuccessful();

          // The TS lock file (package-lock.json) is unchanged.
          when(
            () => processWrapper.run('git', [
              'status',
              '--porcelain',
              'package-lock.json',
            ], workingDirectory: d.path),
          ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

          // The TS version tag is added via the (mocked) process wrapper.
          when(
            () => processWrapper.run('git', [
              'tag',
              '--points-at',
              'HEAD',
            ], workingDirectory: d.path),
          ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
          when(
            () => processWrapper.run('git', [
              'tag',
              '-a',
              '1.2.4',
              '-m',
              'Version 1.2.4',
            ], workingDirectory: d.path),
          ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

          mockPublishIsSuccessful(success: true, askBeforePublishing: false);
          publishedVersionValue = Version(1, 2, 3);
          mockPublishedVersion();

          messages.clear();

          await doPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          );

          final allMessages = messages.join('\n');
          expect(allMessages, contains('Publishing was successful.'));
          // The TypeScript tag path (do_publish.dart `_publishGit`) ran.
          expect(allMessages, contains('Tag 1.2.4 added.'));

          // package.json was bumped and no CHANGELOG was (re)created.
          final packageJson = await File(join(d.path, 'package.json'))
              .readAsString();
          expect(packageJson, contains('1.2.4'));
          expect(File(join(d.path, 'CHANGELOG.md')).existsSync(), isFalse);

          // The TS tag creation went through the process wrapper.
          verify(
            () => processWrapper.run('git', [
              'tag',
              '-a',
              '1.2.4',
              '-m',
              'Version 1.2.4',
            ], workingDirectory: d.path),
          ).called(1);
        },
      );

      test(
        'tags HEAD via AddGitOnlyVersionTag when there is no manifest',
        () async {
          // Turn the Dart repo into a manifest-less one: drop pubspec.yaml
          // and CHANGELOG.md — the project becomes ProjectType.none.
          await File(join(d.path, 'pubspec.yaml')).delete();
          final changelog = File(join(d.path, 'CHANGELOG.md'));
          if (changelog.existsSync()) {
            await changelog.delete();
          }
          await commitFile(d, '.', message: 'Remove manifest');

          // Recompute the success state for the new working tree.
          await makeLastStateSuccessful();

          final addGitOnlyVersionTag = MockAddGitOnlyVersionTag();
          when(
            () => addGitOnlyVersionTag.exec(
              directory: any(named: 'directory'),
              increment: VersionIncrement.patch,
              channel: ReleaseChannel.stable,
            ),
          ).thenAnswer((_) async => ggLog('Tag 0.0.1 added.'));

          final localDoPublish = DoPublish(
            upgradeDeps: upgradeDeps,
            ggLog: ggLog,
            publish: publish,
            prepareNextVersion: PrepareNextVersion(
              ggLog: ggLog,
              publishedVersion: publishedVersion,
            ),
            canPublish: canPublish,
            configurePublish: makeConfigurePublish(),
            publishedVersion: publishedVersion,
            processWrapper: processWrapper,
            localBranch: localBranch,
            confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
            mergeFlow: noPubGetMergeFlow(),
            addGitOnlyVersionTag: addGitOnlyVersionTag,
          );

          messages.clear();

          await localDoPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
            versionIncrement: 'patch',
            message: 'Publish without manifest',
          );

          final allMessages = messages.join('\n');

          // The prepare-version step was a logged no-op.
          expect(allMessages, contains('Git-only project'));

          // The git-only tag path (do_publish.dart `_publishGit`) ran.
          expect(allMessages, contains('Tag 0.0.1 added.'));
          verify(
            () => addGitOnlyVersionTag.exec(
              directory: any(named: 'directory'),
              increment: VersionIncrement.patch,
              channel: ReleaseChannel.stable,
            ),
          ).called(1);

          // No manifest or CHANGELOG was (re)created.
          expect(File(join(d.path, 'pubspec.yaml')).existsSync(), isFalse);
          expect(File(join(d.path, 'CHANGELOG.md')).existsSync(), isFalse);
        },
      );

      // Builds a DoPublish whose version commit is driven by [commit], on a
      // TypeScript working tree (no CHANGELOG step).
      Future<DoPublish> tsDoPublishWith(GgSystemCommit systemCommit) async {
        await File(join(d.path, 'pubspec.yaml')).delete();
        final changelog = File(join(d.path, 'CHANGELOG.md'));
        if (changelog.existsSync()) {
          await changelog.delete();
        }
        await addAndCommitSampleFile(
          d,
          fileName: 'package.json',
          content: '{\n  "name": "x",\n  "version": "1.2.3"\n}\n',
        );
        await addAndCommitSampleFile(
          d,
          fileName: 'tsconfig.json',
          content: '{}',
        );
        await makeLastStateSuccessful();

        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        return DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          systemCommit: systemCommit,
          prepareNextVersion: PrepareNextVersion(
            ggLog: ggLog,
            publishedVersion: publishedVersion,
          ),
          canPublish: canPublish,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
          mergeFlow: noPubGetMergeFlow(),
        );
      }

      test('tolerates an empty version commit when resuming', () async {
        // Resuming after a failed publish: the version is already committed,
        // so the commit reports "Nothing to commit" — »do publish« must keep
        // going instead of crashing.
        final systemCommit = MockGgSystemCommit();
        when(
          () => systemCommit.commit(
            ggLog: any(named: 'ggLog'),
            directory: any(named: 'directory'),
            message: any(named: 'message'),
            paths: any(named: 'paths'),
            includeUntracked: any(named: 'includeUntracked'),
            ammendWhenNotPushed: any(named: 'ammendWhenNotPushed'),
            userCommitMessage: any(named: 'userCommitMessage'),
            stateKey: any(named: 'stateKey'),
          ),
        ).thenAnswer(
          (_) async => const GgSystemCommitResult(
            userCommitCreated: false,
            systemCommitCreated: false,
            ggOwnedPaths: [],
            foreignPaths: [],
          ),
        );

        final doPublish = await tsDoPublishWith(systemCommit);
        messages.clear();

        // The downstream merge is not the subject here; we only assert the
        // idempotent branch logged its message before continuing.
        try {
          await doPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          );
        } catch (_) {
          // ignore later steps
        }

        expect(
          messages.join('\n'),
          contains('Version 1.2.4 is already prepared — nothing to commit.'),
        );
      });

      test('rethrows non-empty-commit failures during version bump', () async {
        final systemCommit = MockGgSystemCommit();
        when(
          () => systemCommit.commit(
            ggLog: any(named: 'ggLog'),
            directory: any(named: 'directory'),
            message: any(named: 'message'),
            paths: any(named: 'paths'),
            includeUntracked: any(named: 'includeUntracked'),
            ammendWhenNotPushed: any(named: 'ammendWhenNotPushed'),
            userCommitMessage: any(named: 'userCommitMessage'),
            stateKey: any(named: 'stateKey'),
          ),
        ).thenThrow(Exception('disk full'));

        final doPublish = await tsDoPublishWith(systemCommit);
        messages.clear();

        late String exception;
        try {
          await doPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          );
        } catch (e) {
          exception = rmControls(e.toString());
        }

        expect(exception, contains('disk full'));
      });
    });

    group('changelog step idempotency (Dart project)', () {
      // Builds a DoPublish whose commits are driven by [systemCommit], on
      // a Dart working tree — so the CHANGELOG step runs.
      Future<DoPublish> dartDoPublishWith(GgSystemCommit systemCommit) async {
        await makeLastStateSuccessful();
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        return DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          systemCommit: systemCommit,
          prepareNextVersion: PrepareNextVersion(
            ggLog: ggLog,
            publishedVersion: publishedVersion,
          ),
          canPublish: canPublish,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
          mergeFlow: noPubGetMergeFlow(),
        );
      }

      test('tolerates an empty changelog commit when resuming', () async {
        // A run that bumped the version and released the changelog but died
        // before the registry upload leaves both steps done. The changelog
        // release is then a no-op, so its commit reports "Nothing to commit"
        // — »do publish« must continue to the upload instead of crashing,
        // otherwise the package can never be published.
        final systemCommit = MockGgSystemCommit();
        when(
          () => systemCommit.commit(
            ggLog: any(named: 'ggLog'),
            directory: any(named: 'directory'),
            message: any(named: 'message'),
            paths: any(named: 'paths'),
            includeUntracked: any(named: 'includeUntracked'),
            ammendWhenNotPushed: any(named: 'ammendWhenNotPushed'),
            userCommitMessage: any(named: 'userCommitMessage'),
            stateKey: any(named: 'stateKey'),
          ),
        ).thenAnswer(
          (_) async => const GgSystemCommitResult(
            userCommitCreated: false,
            systemCommitCreated: false,
            ggOwnedPaths: [],
            foreignPaths: [],
          ),
        );

        final doPublish = await dartDoPublishWith(systemCommit);
        messages.clear();

        // The downstream merge is not the subject here; we only assert the
        // idempotent branch logged its message before continuing.
        try {
          await doPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          );
        } catch (_) {
          // ignore later steps
        }

        expect(
          messages.join('\n'),
          contains('The changelog is already released — nothing to commit.'),
        );
      });

      test('rethrows non-empty-commit failures during changelog', () async {
        final systemCommit = MockGgSystemCommit();
        var callCount = 0;
        when(
          () => systemCommit.commit(
            ggLog: any(named: 'ggLog'),
            directory: any(named: 'directory'),
            message: any(named: 'message'),
            paths: any(named: 'paths'),
            includeUntracked: any(named: 'includeUntracked'),
            ammendWhenNotPushed: any(named: 'ammendWhenNotPushed'),
            userCommitMessage: any(named: 'userCommitMessage'),
            stateKey: any(named: 'stateKey'),
          ),
        ).thenAnswer((_) async {
          // The version commit finds nothing to do, the changelog commit
          // fails for an unrelated reason and must surface.
          callCount++;
          if (callCount == 1) {
            return const GgSystemCommitResult(
              userCommitCreated: false,
              systemCommitCreated: false,
              ggOwnedPaths: [],
              foreignPaths: [],
            );
          }
          throw Exception('disk full');
        });

        final doPublish = await dartDoPublishWith(systemCommit);
        messages.clear();

        await expectLater(
          doPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          ),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('disk full'),
            ),
          ),
        );
      });
    });

    group('merge strategy detection', () {
      test('uses the local merge flow when origin has no remote', () async {
        // git config exits non-zero → no provider → local merge.
        when(
          () => processWrapper.run(
            'git',
            ['config', '--get', 'remote.origin.url'],
            runInShell: true,
            workingDirectory: d.path,
          ),
        ).thenAnswer((_) async => ProcessResult(1, 1, '', ''));

        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        messages.clear();
        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
        );

        expect(messages.join('\n'), contains('✓ Tag 1.2.4 added.'));
      });

      test('warns and merges locally on an unsupported provider', () async {
        // The default remote stub points to git.example.com — no PR support.
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        messages.clear();
        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
        );

        final allMessages = messages.join('\n');
        expect(allMessages, contains('does not support the pull-request flow'));
        expect(allMessages, contains('✓ Tag 1.2.4 added.'));
      });

      test(
        '--no-pr forces the local merge flow on a supported remote',
        () async {
          // Azure remote — but --no-pr keeps the local merge + direct push.
          when(
            () => processWrapper.run(
              'git',
              ['config', '--get', 'remote.origin.url'],
              runInShell: true,
              workingDirectory: d.path,
            ),
          ).thenAnswer(
            (_) async => ProcessResult(
              0,
              0,
              'https://dev.azure.com/org/proj/_git/repo',
              '',
            ),
          );

          mockPublishIsSuccessful(success: true, askBeforePublishing: false);
          publishedVersionValue = Version(1, 2, 3);
          mockPublishedVersion();

          messages.clear();
          final runner = CommandRunner<void>('gg', 'gg')..addCommand(doPublish);
          await runner.run([
            'publish',
            '-i',
            d.path,
            '--no-pr',
            '--no-ask-before-publishing',
            '--no-delete-feature-branch',
          ]);

          // A pull-request flow would fail in this sandbox (no az/gh remote);
          // the successful tag proves the local merge ran.
          expect(messages.join('\n'), contains('✓ Tag 1.2.4 added.'));
        },
      );

      test('removes the .gg/ticket.json marker before the registry '
          'upload', () async {
        // »gg multi do add« force-adds the marker to the feature branch. The
        // registry upload happens BEFORE the merge, so waiting for the
        // merge-time removal would ship the marker to pub.dev/npm inside the
        // published package.

        // This is the one test that runs the real »do push«, so it is the one
        // that reaches »can push« → »pub get --offline«. That generates
        // .dart_tool/ and pubspec.lock, so give the repo the two things a
        // real one has: .dart_tool/ ignored and the lock file committed.
        // Without them »isCommitted« trips over files pub just wrote.
        await File(join(d.path, '.gitignore')).writeAsString('.dart_tool/\n');
        await Process.run('dart', [
          'pub',
          'get',
          '--offline',
        ], workingDirectory: d.path);
        await Process.run('git', [
          'add',
          '.gitignore',
          'pubspec.lock',
        ], workingDirectory: d.path);
        await Process.run('git', [
          'commit',
          '-m',
          'Add lock file',
        ], workingDirectory: d.path);

        final ggDir = Directory(join(d.path, '.gg'));
        if (!ggDir.existsSync()) {
          ggDir.createSync();
        }
        final marker = File(join(ggDir.path, 'ticket.json'))
          ..writeAsStringSync('{"issue_id":"feat_abc"}');
        await Process.run('git', [
          'add',
          '-f',
          '.gg/ticket.json',
        ], workingDirectory: d.path);
        await Process.run('git', [
          'commit',
          '-m',
          'Add ticket marker',
        ], workingDirectory: d.path);
        await pushLocalChangesUpstream(d, 'feat_abc');
        await makeLastStateSuccessful();

        var markerPresentAtUpload = true;
        when(
          () => publish.exec(
            directory: dMock(),
            ggLog: ggLog,
            askBeforePublishing: false,
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        ).thenAnswer((_) async {
          markerPresentAtUpload = marker.existsSync();
          publishedVersionValue = Version.parse('1.2.4');
          ggLog('Publishing was successful.');
        });
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();
        messages.clear();

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
        );

        expect(markerPresentAtUpload, isFalse);
        expect(marker.existsSync(), isFalse);
        expect(messages.join('\n'), contains('Removed .gg/ticket.json.'));
      });

      test('merges via a pull request on a protected (Azure) remote', () async {
        final mockMergeFlow = MockMergeFlow();
        when(
          () => mockMergeFlow.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            automerge: any(named: 'automerge'),
            local: any(named: 'local'),
            message: any(named: 'message'),
            verbose: any(named: 'verbose'),
            viaPullRequest: any(named: 'viaPullRequest'),
            deleteSourceBranch: any(named: 'deleteSourceBranch'),
          ),
        ).thenAnswer((_) async {
          // The real pull-request flow ends with the local main REF moved
          // to the merged state — without a checkout, HEAD stays on the
          // feature branch. The tag step that follows the upload relies on
          // the ref. Emulate it with the same plumbing the real flow uses.
          final tree = await Process.run('git', [
            'rev-parse',
            'HEAD:',
          ], workingDirectory: d.path);
          final squash = await Process.run('git', [
            'commit-tree',
            (tree.stdout as String).trim(),
            '-p',
            'main',
            '-m',
            'PR squash commit',
          ], workingDirectory: d.path);
          await Process.run('git', [
            'update-ref',
            'refs/heads/main',
            (squash.stdout as String).trim(),
          ], workingDirectory: d.path);
        });
        when(
          () => mockMergeFlow.removeTicketJson(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            verbose: any(named: 'verbose'),
          ),
        ).thenAnswer((_) async {});

        // Azure remote → pull-request flow.
        when(
          () => processWrapper.run(
            'git',
            ['config', '--get', 'remote.origin.url'],
            runInShell: true,
            workingDirectory: d.path,
          ),
        ).thenAnswer(
          (_) async => ProcessResult(
            0,
            0,
            'https://dev.azure.com/org/proj/_git/repo',
            '',
          ),
        );

        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        final azurePublish = DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          prepareNextVersion: PrepareNextVersion(
            ggLog: ggLog,
            publishedVersion: publishedVersion,
          ),
          canPublish: canPublish,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
          mergeFlow: mockMergeFlow,
        );

        messages.clear();
        await azurePublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: true,
        );

        // The merge went through the pull-request path, forwarding the
        // delete decision to the provider.
        verify(
          () => mockMergeFlow.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            automerge: any(named: 'automerge'),
            local: any(named: 'local'),
            message: any(named: 'message'),
            verbose: any(named: 'verbose'),
            viaPullRequest: true,
            deleteSourceBranch: true,
          ),
        ).called(1);

        // The branch deletion runs here too — idempotent when the provider
        // already deleted the source branch on auto-complete.
        verify(
          () => processWrapper.run('git', [
            'push',
            'origin',
            '--delete',
            'feat_abc',
          ], workingDirectory: d.path),
        ).called(1);
      });
    });

    group('merge before publish (the release order)', () {
      test('merges into main BEFORE the registry upload — and uploads '
          'from the feature branch', () async {
        String? branchAtUpload;
        bool? mergedAtUpload;
        when(
          () => publish.exec(
            directory: dMock(),
            ggLog: ggLog,
            askBeforePublishing: false,
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        ).thenAnswer((_) async {
          final branch = await Process.run('git', [
            'rev-parse',
            '--abbrev-ref',
            'HEAD',
          ], workingDirectory: d.path);
          branchAtUpload = (branch.stdout as String).trim();

          // Does main already carry the release content when the upload
          // starts? The bumped pubspec.yaml is the release marker.
          final diff = await Process.run('git', [
            'diff',
            '--quiet',
            'main',
            'HEAD',
            '--',
            'pubspec.yaml',
          ], workingDirectory: d.path);
          mergedAtUpload = diff.exitCode == 0;

          publishedVersionValue = Version.parse('1.2.4');
          ggLog('Publishing was successful.');
        });
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
        );

        // The upload ran on the feature branch, whose content the merge
        // had already brought onto the default branch.
        expect(branchAtUpload, 'feat_abc');
        expect(mergedAtUpload, isTrue);
      });

      test('records doCommit and doPush before the merge, so the '
          'merge itself carries them into main', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
        );

        // The COMMITTED .gg/gg.json of the default branch carries both
        // states — in the pull-request flow no push to main could have
        // added them afterwards.
        final committed = await Process.run('git', [
          'show',
          'main:.gg/gg.json',
        ], workingDirectory: d.path);
        final json =
            jsonDecode(committed.stdout as String) as Map<String, dynamic>;
        expect(json.containsKey('doCommit'), isTrue);
        expect(json.containsKey('doPush'), isTrue);

        // »gg did publish« needs no recorded marker — it reads the tag the
        // release just created.
        await Process.run('git', [
          'checkout',
          'main',
        ], workingDirectory: d.path);
        expect(
          await DidPublish(ggLog: ggLog).get(directory: d, ggLog: ggLog),
          isTrue,
        );
      });

      test('a refused merge stops the release before anything reaches '
          'a registry', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        final failingMergeFlow = MockMergeFlow();
        when(
          () => failingMergeFlow.removeTicketJson(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            verbose: any(named: 'verbose'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => failingMergeFlow.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            automerge: any(named: 'automerge'),
            local: any(named: 'local'),
            message: any(named: 'message'),
            verbose: any(named: 'verbose'),
            viaPullRequest: any(named: 'viaPullRequest'),
            deleteSourceBranch: any(named: 'deleteSourceBranch'),
          ),
        ).thenThrow(Exception('Merge was rejected'));

        final mergeFirstPublish = DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          prepareNextVersion: PrepareNextVersion(
            ggLog: ggLog,
            publishedVersion: publishedVersion,
          ),
          canPublish: canPublish,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
          mergeFlow: failingMergeFlow,
        );

        await expectLater(
          () => mergeFirstPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('Merge was rejected'),
            ),
          ),
        );

        // Nothing was uploaded — a registry cannot take a version back,
        // while the merged-but-not-uploaded state is simply resumable.
        verifyNever(
          () => publish.exec(
            directory: any<Directory>(named: 'directory'),
            ggLog: any<GgLog>(named: 'ggLog'),
            askBeforePublishing: any<bool>(named: 'askBeforePublishing'),
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        );
      });

      test('throws when the push of the merged default branch fails — '
          'before anything reaches a registry', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        when(
          () => processWrapper.run('git', [
            'push',
            'origin',
            'main',
          ], workingDirectory: d.path),
        ).thenAnswer((_) async => ProcessResult(0, 1, '', 'remote rejected'));

        await expectLater(
          () => doPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          ),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              allOf(
                contains('git push origin main failed'),
                contains('remote rejected'),
              ),
            ),
          ),
        );

        // The merge never became durable on the remote — so nothing was
        // uploaded either.
        verifyNever(
          () => publish.exec(
            directory: any<Directory>(named: 'directory'),
            ggLog: any<GgLog>(named: 'ggLog'),
            askBeforePublishing: any<bool>(named: 'askBeforePublishing'),
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        );
      });

      test('ends back on the feature branch', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
        );

        final branch = await Process.run('git', [
          'rev-parse',
          '--abbrev-ref',
          'HEAD',
        ], workingDirectory: d.path);
        expect((branch.stdout as String).trim(), 'feat_abc');
      });

      test('throws when the switch back to the feature branch fails', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        when(
          () => processWrapper.run('git', [
            'checkout',
            'feat_abc',
          ], workingDirectory: d.path),
        ).thenAnswer((_) async => ProcessResult(0, 1, '', 'boom'));

        await expectLater(
          () => doPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          ),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('git checkout feat_abc failed'),
            ),
          ),
        );
      });
    });

    group('configure + resume', () {
      late File runtimeFile;

      setUp(() {
        runtimeFile = File(join(d.path, '.gg', 'gg-publish.json'));
      });

      void stubGit(List<String> args, {int exitCode = 0}) {
        when(() => processWrapper.run('git', args, workingDirectory: d.path))
            .thenAnswer((_) async => ProcessResult(0, exitCode, '', ''));
      }

      AddVersionTag mockAddVersionTag() {
        final tag = _MockAddVersionTag();
        when(
          () => tag.exec(
            directory: any<Directory>(named: 'directory'),
            ggLog: any<GgLog>(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});
        return tag;
      }

      DoPublish makeResumePublish({
        AddVersionTag? addVersionTag,
        EditMessage? editMessage,
        ConfirmDeleteFeatureBranch? confirmDeleteFeatureBranch,
      }) => DoPublish(
        upgradeDeps: upgradeDeps,
        waitUntilPublished: waitUntilPublished,
        ggLog: ggLog,
        publish: publish,
        prepareNextVersion: PrepareNextVersion(
          ggLog: ggLog,
          publishedVersion: publishedVersion,
        ),
        canPublish: canPublish,
        addVersionTag: addVersionTag ?? mockAddVersionTag(),
        configurePublish: makeConfigurePublish(
          editMessage:
              editMessage ??
              (_) async => fail('Editor must not open on a resumed run.'),
        ),
        publishedVersion: publishedVersion,
        processWrapper: processWrapper,
        localBranch: localBranch,
        confirmDeleteFeatureBranch:
            confirmDeleteFeatureBranch ?? defaultConfirmDeleteFeatureBranch,
        mergeFlow: noPubGetMergeFlow(),
      );

      test('--continue without a saved run throws a clear error', () async {
        final runner = CommandRunner<void>('gg', 'gg')..addCommand(doPublish);
        await expectLater(
          () => runner.run(['publish', '-i', d.path, '--continue']),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('Nothing to continue'),
            ),
          ),
        );
      });

      test('--continue resumes a run that failed before its first '
          'step', () async {
        // The regression this guards: a run that died in `can publish`
        // records no step, only the answers. Resuming is then a normal run —
        // refusing it would be a dead end.
        await RepoPublishConfig(
          versionIncrement: VersionIncrement.patch,
          mergeMessage: 'm',
        ).save(file: DoConfigurePublish.configFileFor(d));

        final runner = CommandRunner<void>('gg', 'gg')..addCommand(doPublish);
        // It gets past the guard — whatever the half-stubbed flow fails on
        // afterwards, it is no longer »nothing to continue«.
        Object? error;
        try {
          await runner.run(['publish', '-i', d.path, '--continue']);
        } catch (e) {
          error = e;
        }
        expect(rmControls('$error'), isNot(contains('Nothing to continue')));
      });

      test('--continue rejects --config and --restart', () async {
        Matcher throwsCombineError() => throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('cannot be combined'),
          ),
        );
        await expectLater(
          () => (CommandRunner<void>('gg', 'gg')..addCommand(doPublish)).run([
            'publish',
            '-i',
            d.path,
            '--continue',
            '--config',
            'x.json',
          ]),
          throwsCombineError(),
        );
        await expectLater(
          () =>
              (CommandRunner<void>('gg', 'gg')..addCommand(makeResumePublish()))
                  .run(['publish', '-i', d.path, '--continue', '--restart']),
          throwsCombineError(),
        );
      });

      test(
        'a plain re-run refuses a runtime file that holds progress',
        () async {
          runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "done_steps": ["prepare_version"]
}
''');
          await expectLater(
            () => doPublish.exec(directory: d, ggLog: ggLog),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('Unfinished publish in'),
              ),
            ),
          );
        },
      );

      group('stale progress recorded on another branch', () {
        // Progress that belongs to a different feature branch arrived with a
        // copy of the repository (the file is gitignored, so e.g. copying
        // the master workspace into a ticket used to carry it along). It
        // must never block or corrupt the publish of the current branch.
        const staleProgress = '''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_other",
  "done_steps": ["prepare_version", "publish_registry_pub_dev"]
}
''';

        test('a fresh run discards it and publishes normally', () async {
          mockPublishIsSuccessful(success: true, askBeforePublishing: false);
          runtimeFile.writeAsStringSync(staleProgress);

          await doPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            message: 'Fresh publish',
            versionIncrement: 'patch',
            deleteFeatureBranch: false,
          );

          final allMessages = messages.join('\n');
          expect(allMessages, contains('stale leftover of another publish'));
          expect(
            allMessages,
            isNot(contains('Resuming the unfinished publish')),
          );
          // The upload ran — the alien "publish_registry" marker was not
          // trusted.
          verify(
            () => publish.exec(
              directory: dMock(),
              ggLog: ggLog,
              askBeforePublishing: false,
              targets: any(named: 'targets'),
              onPublished: any(named: 'onPublished'),
            ),
          ).called(1);
          // The runtime file is removed after the successful publish.
          expect(runtimeFile.existsSync(), isFalse);
        });

        test('--continue refuses and deletes the stale file', () async {
          runtimeFile.writeAsStringSync(staleProgress);
          final runner = CommandRunner<void>('gg', 'gg')
            ..addCommand(makeResumePublish());
          await expectLater(
            () => runner.run(['publish', '-i', d.path, '--continue']),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                allOf(
                  contains('stale leftover of another publish'),
                  contains('There is nothing to continue'),
                ),
              ),
            ),
          );
          expect(runtimeFile.existsSync(), isFalse);
        });

        test('progress is kept when HEAD is on the default branch', () async {
          // After its merge a resumed run legitimately sits on the default
          // branch — the branch mismatch does not make the progress stale.
          when(
            () => localBranch.get(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenAnswer((_) async => 'main');
          runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_abc",
  "done_steps": ["prepare_version", "publish_registry_pub_dev", "merge"]
}
''');
          stubGit(['rev-parse', '--verify', '--quiet', 'refs/heads/main']);
          final tag = mockAddVersionTag();
          final resumePublish = makeResumePublish(addVersionTag: tag);
          final runner = CommandRunner<void>('gg', 'gg')
            ..addCommand(resumePublish);
          await runner.run([
            'publish',
            '-i',
            d.path,
            '--continue',
            '--no-delete-feature-branch',
          ]);

          final allMessages = messages.join('\n');
          expect(allMessages, contains('Resuming the unfinished publish'));
          expect(
            allMessages,
            isNot(contains('stale leftover of another publish')),
          );
          expect(runtimeFile.existsSync(), isFalse);
        });
      });

      test('reuses an existing config file without prompting', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        runtimeFile.writeAsStringSync(
          '{"version_increment":"patch",'
          '"merge_message":"From runtime file"}',
        );

        final strictPublish = DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          prepareNextVersion: PrepareNextVersion(
            ggLog: ggLog,
            publishedVersion: publishedVersion,
          ),
          canPublish: canPublish,
          configurePublish: makeConfigurePublish(
            editMessage: (_) async =>
                fail('Editor must not open when the config file exists.'),
          ),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
          mergeFlow: noPubGetMergeFlow(),
        );

        await strictPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
        );

        final headMessage = await mergeMessageBelowStateCommit(d);
        expect(headMessage, 'From runtime file');
        // The runtime file is removed after the successful publish.
        expect(runtimeFile.existsSync(), isFalse);
      });

      test('--continue resumes at the open tag step', () async {
        // prepare/registry/merge already done; HEAD still on feat_abc as
        // after a gg_multi keep-commits restore.
        runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_abc",
  "done_steps": ["prepare_version", "publish_registry_pub_dev", "merge"]
}
''');
        stubGit(['rev-parse', '--verify', '--quiet', 'refs/heads/main']);
        stubGit(['checkout', 'main']);
        final tag = mockAddVersionTag();
        final resumePublish = makeResumePublish(addVersionTag: tag);

        final runner = CommandRunner<void>('gg', 'gg')
          ..addCommand(resumePublish);
        await runner.run([
          'publish',
          '-i',
          d.path,
          '--continue',
          '--no-delete-feature-branch',
        ]);

        final allMessages = messages.join('\n');
        expect(allMessages, contains('Resuming the unfinished publish'));
        expect(allMessages, contains('Checked out main.'));
        // The registry publish was skipped — the step was already done.
        verifyNever(
          () => publish.exec(
            directory: any<Directory>(named: 'directory'),
            ggLog: any<GgLog>(named: 'ggLog'),
            askBeforePublishing: any<bool>(named: 'askBeforePublishing'),
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        );
        // The default branch was checked out exactly once — for the tag
        // step; the main push moves the bare ref without a checkout. The
        // tag was added there.
        verify(
          () => processWrapper.run('git', [
            'checkout',
            'main',
          ], workingDirectory: d.path),
        ).called(1);
        verify(
          () => tag.exec(
            directory: any<Directory>(named: 'directory'),
            ggLog: any<GgLog>(named: 'ggLog'),
          ),
        ).called(1);
        expect(runtimeFile.existsSync(), isFalse);
      });

      test(
        'resume: true (multi flow) skips done steps without CLI flags',
        () async {
          runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_abc",
  "delete_feature_branch": false,
  "done_steps": ["prepare_version"]
}
''');
          // The un-bumped version equals the registry version — the registry
          // safety net skips the publish step.
          publishedVersionValue = Version(1, 2, 3);
          mockPublishedVersion();

          // No deleteFeatureBranch parameter: with increment + message given
          // as parameters, the open delete decision comes from the runtime
          // file — no prompt.
          final resumePublish = makeResumePublish(
            confirmDeleteFeatureBranch: (_) async =>
                fail('The stored decision applies — no prompt.'),
          );
          await resumePublish.exec(
            directory: d,
            ggLog: ggLog,
            resume: true,
            message: 'Resumed merge',
            versionIncrement: 'patch',
            askBeforePublishing: false,
          );

          expect(
            messages.join('\n'),
            contains('Resuming the unfinished publish'),
          );
          verifyNever(
            () => publish.exec(
              directory: any<Directory>(named: 'directory'),
              ggLog: any<GgLog>(named: 'ggLog'),
              askBeforePublishing: any<bool>(named: 'askBeforePublishing'),
              targets: any(named: 'targets'),
              onPublished: any(named: 'onPublished'),
            ),
          );
          // Explicit parameters win over the runtime file values.
          final headMessage = await mergeMessageBelowStateCommit(d);
          expect(headMessage, 'Resumed merge');
          expect(runtimeFile.existsSync(), isFalse);
        },
      );

      test('the persisted branch wins over HEAD for the delete step', () async {
        // After its merge the resumed run sits on the default branch — the
        // branch to delete must come from the runtime file, not from HEAD.
        // The interrupted publish ran on a real feat_other branch, which
        // still exists locally when the resume switches back to it.
        await Process.run('git', [
          'branch',
          'feat_other',
        ], workingDirectory: d.path);
        await Process.run('git', [
          'push',
          '-u',
          'origin',
          'feat_other',
        ], workingDirectory: d.path);
        when(
          () => localBranch.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async => 'main');
        runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_other",
  "done_steps": ["prepare_version", "publish_registry_pub_dev", "merge"]
}
''');
        stubGit(['rev-parse', '--verify', '--quiet', 'refs/heads/main']);
        stubGit(['checkout', 'main']);
        stubGit(['push', 'origin', '--delete', 'feat_other']);

        final resumePublish = makeResumePublish();
        await resumePublish.exec(
          directory: d,
          ggLog: ggLog,
          resume: true,
          deleteFeatureBranch: true,
        );

        // The branch recorded at publish start is deleted — not the branch
        // HEAD happens to be on now.
        verify(
          () => processWrapper.run('git', [
            'push',
            'origin',
            '--delete',
            'feat_other',
          ], workingDirectory: d.path),
        ).called(1);
        verifyNever(
          () => processWrapper.run('git', [
            'push',
            'origin',
            '--delete',
            'feat_abc',
          ], workingDirectory: d.path),
        );
      });

      test(
        'a resume reuses the stored delete decision without a prompt',
        () async {
          // After its merge the resumed run sits on the default branch. The
          // interrupted publish ran on a real feat_other branch, which
          // still exists locally when the resume switches back to it.
          await Process.run('git', [
            'branch',
            'feat_other',
          ], workingDirectory: d.path);
          await Process.run('git', [
            'push',
            '-u',
            'origin',
            'feat_other',
          ], workingDirectory: d.path);
          when(
            () => localBranch.get(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenAnswer((_) async => 'main');
          runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_other",
  "delete_feature_branch": true,
  "done_steps": ["prepare_version", "publish_registry_pub_dev", "merge"]
}
''');
          stubGit(['rev-parse', '--verify', '--quiet', 'refs/heads/main']);
          stubGit(['checkout', 'main']);
          stubGit(['push', 'origin', '--delete', 'feat_other']);

          final runner = CommandRunner<void>('gg', 'gg')
            ..addCommand(
              makeResumePublish(
                confirmDeleteFeatureBranch: (_) async =>
                    fail('The stored decision applies — no prompt on resume.'),
              ),
            );
          await runner.run(['publish', '-i', d.path, '--continue']);

          verify(
            () => processWrapper.run('git', [
              'push',
              'origin',
              '--delete',
              'feat_other',
            ], workingDirectory: d.path),
          ).called(1);
        },
      );

      test(
        'a resumed delete tolerates an already-deleted remote branch',
        () async {
          // The delete re-runs on resume (a multi-flow resume may have
          // re-pushed the branch); a remote ref that is already gone must
          // not fail the run. After its merge the run sits on the default
          // branch; the local feat_other branch of the interrupted publish
          // still exists.
          await Process.run('git', [
            'branch',
            'feat_other',
          ], workingDirectory: d.path);
          await Process.run('git', [
            'push',
            '-u',
            'origin',
            'feat_other',
          ], workingDirectory: d.path);
          when(
            () => localBranch.get(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenAnswer((_) async => 'main');
          runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_other",
  "done_steps": ["prepare_version", "publish_registry_pub_dev", "merge"]
}
''');
          stubGit(['rev-parse', '--verify', '--quiet', 'refs/heads/main']);
          stubGit(['checkout', 'main']);
          when(
            () => processWrapper.run('git', [
              'push',
              'origin',
              '--delete',
              'feat_other',
            ], workingDirectory: d.path),
          ).thenAnswer(
            (_) async => ProcessResult(
              0,
              1,
              '',
              "error: unable to delete 'feat_other': "
                  'remote ref does not exist',
            ),
          );

          final resumePublish = makeResumePublish();
          await resumePublish.exec(
            directory: d,
            ggLog: ggLog,
            resume: true,
            deleteFeatureBranch: true,
          );

          expect(
            messages.join('\n'),
            contains('Remote feature branch feat_other was already deleted.'),
          );
        },
      );

      test(
        'a fresh run ignores the branch of a leftover config-only file',
        () async {
          // A run that failed before its first step (e.g. in canPublish)
          // leaves a config-only file with a recorded branch. A later fresh
          // publish of a DIFFERENT branch must not delete that stale branch.
          mockPublishIsSuccessful(success: true, askBeforePublishing: false);
          runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_other"
}
''');

          final freshPublish = makeResumePublish(
            editMessage: (_) async =>
                fail('Editor must not open when the config file exists.'),
          );
          await freshPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: true,
          );

          // HEAD's branch (feat_abc) is deleted — not the stale feat_other.
          verify(
            () => processWrapper.run('git', [
              'push',
              'origin',
              '--delete',
              'feat_abc',
            ], workingDirectory: d.path),
          ).called(1);
          verifyNever(
            () => processWrapper.run('git', [
              'push',
              'origin',
              '--delete',
              'feat_other',
            ], workingDirectory: d.path),
          );
        },
      );

      test(
        'a resume aborts when raw commits were added after the failure',
        () async {
          runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_abc",
  "done_steps": ["prepare_version"]
}
''');
          // A raw git commit (not via gg do commit) invalidates the
          // hash-keyed doCommit marker.
          await addAndCommitSampleFile(
            d,
            fileName: 'sneaked_in.txt',
            content: 'unvalidated',
          );

          await expectLater(
            () => makeResumePublish().exec(
              directory: d,
              ggLog: ggLog,
              resume: true,
              deleteFeatureBranch: false,
            ),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('The repository changed since the failed publish'),
              ),
            ),
          );
        },
      );

      group('default-branch checkout on a resumed merge', () {
        Future<void> writeMergedRuntimeFile() async {
          runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "branch": "feat_abc",
  "done_steps": ["prepare_version", "publish_registry_pub_dev", "merge"]
}
''');
        }

        test('falls back to master when main does not exist', () async {
          await writeMergedRuntimeFile();
          stubGit([
            'rev-parse',
            '--verify',
            '--quiet',
            'refs/heads/main',
          ], exitCode: 1);
          stubGit(['rev-parse', '--verify', '--quiet', 'refs/heads/master']);
          stubGit(['checkout', 'master']);
          stubGit(['push', 'origin', 'master']);

          await makeResumePublish().exec(
            directory: d,
            ggLog: ggLog,
            resume: true,
            deleteFeatureBranch: false,
          );

          // Exactly once — for the tag step; the main push moves the bare
          // ref without a checkout.
          verify(
            () => processWrapper.run('git', [
              'checkout',
              'master',
            ], workingDirectory: d.path),
          ).called(1);
        });

        test('does not check out when already on the default branch', () async {
          await writeMergedRuntimeFile();
          stubGit(['rev-parse', '--verify', '--quiet', 'refs/heads/main']);
          when(
            () => localBranch.get(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          ).thenAnswer((_) async => 'main');

          await makeResumePublish().exec(
            directory: d,
            ggLog: ggLog,
            resume: true,
            deleteFeatureBranch: false,
          );

          verifyNever(
            () => processWrapper.run('git', [
              'checkout',
              'main',
            ], workingDirectory: d.path),
          );
        });

        test('tolerates a repo without main and master', () async {
          await writeMergedRuntimeFile();
          stubGit([
            'rev-parse',
            '--verify',
            '--quiet',
            'refs/heads/main',
          ], exitCode: 1);
          stubGit([
            'rev-parse',
            '--verify',
            '--quiet',
            'refs/heads/master',
          ], exitCode: 1);

          await makeResumePublish().exec(
            directory: d,
            ggLog: ggLog,
            resume: true,
            deleteFeatureBranch: false,
          );

          expect(runtimeFile.existsSync(), isFalse);
        });

        test('throws when the checkout fails', () async {
          await writeMergedRuntimeFile();
          stubGit(['rev-parse', '--verify', '--quiet', 'refs/heads/main']);
          stubGit(['checkout', 'main'], exitCode: 1);

          await expectLater(
            () => makeResumePublish().exec(
              directory: d,
              ggLog: ggLog,
              resume: true,
              deleteFeatureBranch: false,
            ),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls(e.toString()),
                'message',
                contains('git checkout main failed'),
              ),
            ),
          );
        });
      });

      test('--restart discards config and progress and reconfigures', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);
        runtimeFile.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "stale",
  "done_steps": ["prepare_version"]
}
''');

        final restartPublish = makeResumePublish(
          addVersionTag: AddVersionTag(ggLog: ggLog),
          editMessage: (_) async => 'Reconfigured',
        );
        final runner = CommandRunner<void>('gg', 'gg')
          ..addCommand(restartPublish);
        await runner.run([
          'publish',
          '-i',
          d.path,
          '--restart',
          '--no-ask-before-publishing',
          '--no-delete-feature-branch',
        ]);

        final headMessage = await mergeMessageBelowStateCommit(d);
        expect(headMessage, 'Reconfigured');
        expect(runtimeFile.existsSync(), isFalse);
      });
    });

    group('when a previous publish left the version tag behind', () {
      test('removes it locally and on the remote and re-tags the '
          'release commit', () async {
        // A publish that failed after tagging leaves tag 1.2.4 on a commit
        // this run replaces. Without removing it »add version tag« refuses
        // ("must be greater 1.2.4") and the release stays untagged.
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        final abandoned = await Process.run('git', [
          'rev-parse',
          'HEAD',
        ], workingDirectory: d.path);
        await addTag(d, '1.2.4');
        await Process.run('git', [
          'push',
          'origin',
          '--tags',
        ], workingDirectory: d.path);

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
        );

        final allMessages = messages.join('\n');
        expect(allMessages, contains('✓ Removed the local tag 1.2.4.'));
        expect(allMessages, contains('✓ Removed the remote tag 1.2.4.'));
        expect(allMessages, contains('✓ Tag 1.2.4 added.'));

        // The tag was recreated on the release commit of the default
        // branch, not on the abandoned one - locally as well as on the
        // remote.
        final releaseCommit = await Process.run('git', [
          'rev-parse',
          'main',
        ], workingDirectory: d.path);
        expect(releaseCommit.stdout, isNot(abandoned.stdout));

        final tagged = await Process.run('git', [
          'rev-list',
          '-n',
          '1',
          '1.2.4',
        ], workingDirectory: d.path);
        expect(tagged.stdout, releaseCommit.stdout);

        // The remote now carries the recreated (annotated) tag object, and no
        // longer the lightweight tag of the abandoned commit.
        final remoteTag = await Process.run('git', [
          'ls-remote',
          '--tags',
          'origin',
          'refs/tags/1.2.4',
        ], workingDirectory: d.path);
        final localTagObject = await Process.run('git', [
          'rev-parse',
          'refs/tags/1.2.4',
        ], workingDirectory: d.path);
        expect(
          remoteTag.stdout as String,
          contains((localTagObject.stdout as String).trim()),
        );
        expect(
          remoteTag.stdout as String,
          isNot(contains((abandoned.stdout as String).trim())),
        );
      });

      test('logs nothing about tags when none was left behind', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
        );

        final allMessages = messages.join('\n');
        expect(allMessages, isNot(contains('to be removed')));
        expect(allMessages, contains('✓ Tag 1.2.4 added.'));
      });
    });

    group('merge only', () {
      // Reads the tags of the test repository.
      Future<List<String>> tagsOf(Directory dir) async {
        final result = await Process.run('git', [
          'tag',
          '--list',
        ], workingDirectory: dir.path);
        return (result.stdout as String)
            .split('\n')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList();
      }

      test('never asks for a version increment', () async {
        // A merge-only run creates no release, so the increment prompt of
        // »do configure-publish« must not appear — neither directly nor
        // through the config file it writes.
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
          mergeOnly: true,
        );

        verifyNever(
          () => versionSelector.selectIncrement(
            currentVersion: any(named: 'currentVersion'),
          ),
        );

        expect(
          await File(join(d.path, 'pubspec.yaml')).readAsString(),
          contains('version: 1.2.3'),
        );
      });

      test('merges without producing any release artifact', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
          mergeOnly: true,
        );

        // The version stays at the released one — no bump, and the changelog
        // keeps its »## Unreleased« section instead of a release heading.
        expect(
          await File(join(d.path, 'pubspec.yaml')).readAsString(),
          contains('version: 1.2.3'),
        );
        final changelog = await File(join(d.path, 'CHANGELOG.md'))
            .readAsString();
        expect(changelog, contains('## Unreleased'));
        expect(changelog, isNot(contains('## 1.2.4')));

        // Nothing was uploaded and no tag was created.
        verifyNever(
          () => publish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        );
        verifyNever(
          () => waitUntilPublished.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        );
        expect(await tagsOf(d), isEmpty);

        // A merge released nothing, so the merged state is not marked
        // published.
        expect(
          await DidPublish(ggLog: ggLog).get(directory: d, ggLog: ggLog),
          isFalse,
        );

        final allMessages = messages.join('\n');
        expect(allMessages, contains('not increasing the version'));
        expect(allMessages, contains('not publishing to a package registry'));
        expect(allMessages, isNot(contains('Tag 1.2.4 added')));
      });

      test('records no publish step at all', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        final steps = <List<String>>[];
        final runtimeFile = DoConfigurePublish.configFileFor(d);
        // Capture the recorded steps while the run is still in progress —
        // the file is deleted when the run succeeds.
        await doPublish.exec(
          directory: d,
          ggLog: (msg) {
            if (runtimeFile.existsSync()) {
              steps.add(
                PublishConfig.load(
                  configArg: runtimeFile.path,
                  fallbackDir: d.path,
                ).doneSteps,
              );
            }
            ggLog(msg);
          },
          askBeforePublishing: false,
          deleteFeatureBranch: false,
          mergeOnly: true,
        );

        // No step ran, so none may be recorded — a marker would make a
        // later »gg do publish --continue« believe the release happened.
        expect(steps, isNotEmpty);
        expect(steps.expand((s) => s), isEmpty);
      });

      test('refuses when references are still localized', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        File(join(d.path, 'pubspec_overrides.yaml')).writeAsStringSync(
          'dependency_overrides:\n  gg_log:\n    path: ../gg_log',
        );

        late String message;
        try {
          await doPublish.exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
            mergeOnly: true,
          );
        } catch (e) {
          message = rmControls(e.toString());
        }

        expect(message, contains('Project depends on other local projects'));
        expect(message, contains('Just merging is not possible'));
        // Both escape hatches are named.
        expect(message, contains('gg do publish'));
        expect(message, contains('--force'));
        // The guard runs before anything is changed.
        expect(
          File(join(d.path, 'pubspec_overrides.yaml')).existsSync(),
          isTrue,
        );
      });

      test('merges localized references when --force is given', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        final overrides = File(join(d.path, 'pubspec_overrides.yaml'))
          ..writeAsStringSync(
            'dependency_overrides:\n  gg_log:\n    path: ../gg_log',
          );

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
          mergeOnly: true,
          force: true,
        );

        // The overrides were removed for the merge itself — the main branch
        // must not carry them — and restored once the feature branch was
        // checked out again, so the ticket workspace keeps its wiring.
        expect(
          messages.join('\n'),
          contains(
            'Saved pubspec_overrides.yaml to '
            '$pubspecOverridesBackupPath and deleted it.',
          ),
        );
        expect(overrides.existsSync(), isTrue);
        expect(
          File(join(d.path, pubspecOverridesBackupPath)).existsSync(),
          isFalse,
        );
        expect(await tagsOf(d), isEmpty);
      });

      test('tolerates an overrides file without effective refs', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        // An empty `dependency_overrides` redirects nothing.
        File(join(d.path, 'pubspec_overrides.yaml'))
            .writeAsStringSync('dependency_overrides:\n');

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
          mergeOnly: true,
        );

        expect(await tagsOf(d), isEmpty);
      });

      test('is available as --merge-only on the command line', () async {
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        final cliDoPublish = DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          prepareNextVersion: PrepareNextVersion(
            ggLog: ggLog,
            publishedVersion: publishedVersion,
          ),
          canPublish: canPublish,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: (_) async => false,
          mergeFlow: noPubGetMergeFlow(),
        );

        final runner = CommandRunner<void>('gg', 'gg')
          ..addCommand(cliDoPublish);

        await runner.run(<String>[
          'publish',
          '-i',
          d.path,
          '--merge-only',
          '--force',
          '--no-delete-feature-branch',
          '--no-ask-before-publishing',
        ]);

        expect(await tagsOf(d), isEmpty);
        expect(
          messages.join('\n'),
          contains('not publishing to a package registry'),
        );
      });
    });

    group('--no-pana', () {
      // The flag only decides what »can publish« is asked to do, so the check
      // is where it arrives: the options map of its exec call.
      Future<Map<String, dynamic>> panaOptionOf(List<String> args) async {
        final mockCanPublish = MockCanPublish();
        late Map<String, dynamic> captured;
        when(
          () => mockCanPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((invocation) async {
          captured =
              invocation.namedArguments[#options] as Map<String, dynamic>;
          // Nothing beyond this point is under test — stop the publish here.
          throw Exception('stop');
        });

        final cliDoPublish = DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          canPublish: mockCanPublish,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
          mergeFlow: noPubGetMergeFlow(),
        );

        final runner = CommandRunner<void>('gg', 'gg')
          ..addCommand(cliDoPublish);
        await expectLater(
          runner.run(<String>['publish', '-i', d.path, ...args]),
          throwsA(isA<Exception>()),
        );
        return captured;
      }

      test('forwards pana: false to »can publish«', () async {
        expect(await panaOptionOf(['--no-pana']), {panaOption: false});
      });

      test('forwards pana: true by default', () async {
        expect(await panaOptionOf(<String>[]), {panaOption: true});
      });

      test('takes the value from the exec options', () async {
        final mockCanPublish = MockCanPublish();
        late Map<String, dynamic> captured;
        when(
          () => mockCanPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((invocation) async {
          captured =
              invocation.namedArguments[#options] as Map<String, dynamic>;
          throw Exception('stop');
        });

        final programmatic = DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          canPublish: mockCanPublish,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
          mergeFlow: noPubGetMergeFlow(),
        );

        await expectLater(
          programmatic.exec(
            directory: d,
            ggLog: ggLog,
            options: const <String, dynamic>{panaOption: false},
          ),
          throwsA(isA<Exception>()),
        );
        expect(captured, {panaOption: false});
      });
    });

    // .......................................................................
    group('dependency upgrade', () {
      // The upgrade sits right before »can publish«, so a mocked
      // »can publish« that throws stops the run exactly behind the step
      // under test — everything beyond it is covered by the tests above.
      DoPublish publishStoppingAtCanPublish() {
        final mockCanPublish = MockCanPublish();
        when(
          () => mockCanPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => throw Exception('stop'));

        return DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          canPublish: mockCanPublish,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
          mergeFlow: noPubGetMergeFlow(),
        );
      }

      test('runs »dart pub upgrade --tighten« before »can publish«', () async {
        await expectLater(
          publishStoppingAtCanPublish().exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          ),
          throwsA(isA<Exception>()),
        );

        verify(
          () => upgradeDeps.exec(
            directory: d,
            ggLog: any(named: 'ggLog'),
          ),
        ).called(1);
      });

      test('commits what the upgrade changed', () async {
        // The upgrade tightens the constraints in pubspec.yaml — a rewrite
        // the publish has to commit before »can publish« reads the tree.
        when(
          () => upgradeDeps.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {
          final pubspec = File(join(d.path, 'pubspec.yaml'));
          await pubspec.writeAsString(
            '${pubspec.readAsStringSync()}\n# tightened\n',
          );
        });

        await expectLater(
          publishStoppingAtCanPublish().exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          ),
          throwsA(isA<Exception>()),
        );

        final head = await Process.run('git', [
          'log',
          '-1',
          '--pretty=%s',
        ], workingDirectory: d.path);

        expect(
          head.stdout,
          contains(
            '${ggCommitPrefix}dart pub upgrade --major-versions '
            '--tighten',
          ),
        );
      });

      test('writes no commit when everything is up to date', () async {
        await expectLater(
          publishStoppingAtCanPublish().exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
          ),
          throwsA(isA<Exception>()),
        );

        // Other steps write their own bookkeeping commits, so the question
        // is not whether HEAD moved — it is whether the upgrade added one.
        final log = await Process.run('git', [
          'log',
          '--pretty=%s',
        ], workingDirectory: d.path);

        expect(log.stdout, isNot(contains('dart pub upgrade')));
      });

      test(
        'is skipped when the caller upgrades itself (upgrade: false)',
        () async {
          await expectLater(
            publishStoppingAtCanPublish().exec(
              directory: d,
              ggLog: ggLog,
              askBeforePublishing: false,
              deleteFeatureBranch: false,
              upgrade: false,
            ),
            throwsA(isA<Exception>()),
          );

          verifyNever(
            () => upgradeDeps.exec(
              directory: any(named: 'directory'),
              ggLog: any(named: 'ggLog'),
            ),
          );
        },
      );

      test('is turned off by --no-upgrade on the command line', () async {
        final runner = CommandRunner<void>('gg', 'gg')
          ..addCommand(publishStoppingAtCanPublish());

        await expectLater(
          runner.run(<String>[
            'publish',
            '-i',
            d.path,
            '--no-upgrade',
            '--no-ask-before-publishing',
            '--no-delete-feature-branch',
          ]),
          throwsA(isA<Exception>()),
        );

        verifyNever(
          () => upgradeDeps.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        );
      });
    });

    // .......................................................................
    group('for a hybrid (pubspec.yaml + package.json)', () {
      late File runtimeFile;
      late File stateFile;

      AddVersionTag mockAddVersionTag() {
        final tag = _MockAddVersionTag();
        when(
          () => tag.exec(
            directory: any<Directory>(named: 'directory'),
            ggLog: any<GgLog>(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});
        return tag;
      }

      DoPublish makeResumePublish({SyncHybridVersions? syncHybridVersions}) =>
          DoPublish(
            upgradeDeps: upgradeDeps,
            syncHybridVersions: syncHybridVersions,
            waitUntilPublished: waitUntilPublished,
            ggLog: ggLog,
            publish: publish,
            prepareNextVersion: PrepareNextVersion(
              ggLog: ggLog,
              publishedVersion: publishedVersion,
            ),
            canPublish: canPublish,
            addVersionTag: mockAddVersionTag(),
            configurePublish: makeConfigurePublish(
              editMessage: (_) async =>
                  fail('Editor must not open on a resumed run.'),
            ),
            publishedVersion: publishedVersion,
            processWrapper: processWrapper,
            localBranch: localBranch,
            confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
            mergeFlow: noPubGetMergeFlow(),
          );

      void stubGit(List<String> args, {int exitCode = 0}) {
        when(() => processWrapper.run('git', args, workingDirectory: d.path))
            .thenAnswer((_) async => ProcessResult(0, exitCode, '', ''));
      }

      setUp(() {
        runtimeFile = DoConfigurePublish.configFileFor(d);
        stateFile = DoConfigurePublish.stateFileFor(d);
      });

      /// Writes the answers and the run progress of an interrupted publish.
      void writeResumeFixture({
        String versionIncrement = 'patch',
        String mergeMessage = 'm',
        String? channel,
        required List<String> doneSteps,
      }) {
        runtimeFile
          ..createSync(recursive: true)
          ..writeAsStringSync(
            RepoPublishConfig(
              mergeMessage: mergeMessage,
              versionIncrement: parseVersionIncrement(versionIncrement),
            ).toJsonString(),
          );
        stateFile
          ..createSync(recursive: true)
          ..writeAsStringSync(
            PublishState(
              branch: 'feat_abc',
              channel: channel,
              deleteFeatureBranch: false,
              doneSteps: doneSteps,
            ).toJsonString(),
          );
      }

      /// Turns the fixture into a hybrid. [packageJsonVersion] drives the
      /// reconciliation; [publishTo] takes the Dart side off pub.dev.
      Future<void> makeHybrid({
        String packageJsonVersion = '1.2.3',
        String? publishTo,
      }) async {
        final pubspec = File(join(d.path, 'pubspec.yaml'));
        var content = pubspec.readAsStringSync();
        if (publishTo != null) {
          content = '$content\npublish_to: $publishTo\n';
        }
        pubspec.writeAsStringSync(content);
        File(join(d.path, 'package.json')).writeAsStringSync(
          '{\n  "name": "@org/test",\n'
          '  "version": "$packageJsonVersion"\n}\n',
        );
        // Commit everything — an untracked package.json leaves the tree dirty
        // and »did commit« would refuse the resume.
        await Process.run('git', ['add', '.'], workingDirectory: d.path);
        await Process.run('git', [
          'commit',
          '-m',
          'Add the node side',
        ], workingDirectory: d.path);
        await makeLastStateSuccessful();
        messages.clear();
      }

      test('publishes to both registries and records both steps', () async {
        // base_dna: no publish_to, no private — both registries are targets.
        await makeHybrid();
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        final published = <PublishTarget>[];
        when(
          () => publish.exec(
            directory: dMock(),
            ggLog: ggLog,
            askBeforePublishing: false,
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        ).thenAnswer((invocation) async {
          final targets =
              invocation.namedArguments[#targets] as Set<PublishTarget>;
          final onPublished =
              invocation.namedArguments[#onPublished]
                  as Future<void> Function(PublishTarget);
          for (final target in targets.toList()) {
            published.add(target);
            await onPublished(target);
          }
          publishedVersionValue = Version(1, 2, 4);
        });

        await doPublish.exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
          message: 'Publish the hybrid',
          versionIncrement: 'patch',
        );

        // Both registries were asked for, pub.dev first.
        expect(published, [PublishTarget.pubDev, PublishTarget.npm]);
        // Both manifests carry the bumped version.
        expect(
          File(join(d.path, 'pubspec.yaml')).readAsStringSync(),
          contains('version: 1.2.4'),
        );
        expect(
          File(join(d.path, 'package.json')).readAsStringSync(),
          contains('"version": "1.2.4"'),
        );
      });

      test('resumes at the registry that is still open', () async {
        // The pub.dev upload succeeded before npm failed — a resume must not
        // upload to pub.dev again.
        await makeHybrid();
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();
        // Neither registry carries the version yet, so only the marker can
        // keep pub.dev out of the resumed upload.
        when(
          () => publishedVersion.latestVersionFor(
            target: any(named: 'target'),
            directory: dMock(),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async => Version(1, 2, 2));

        writeResumeFixture(
          doneSteps: ['prepare_version', 'publish_registry_pub_dev'],
        );

        Set<PublishTarget>? requested;
        when(
          () => publish.exec(
            directory: dMock(),
            ggLog: ggLog,
            askBeforePublishing: false,
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        ).thenAnswer((invocation) async {
          requested = invocation.namedArguments[#targets] as Set<PublishTarget>;
          final onPublished =
              invocation.namedArguments[#onPublished]
                  as Future<void> Function(PublishTarget);
          for (final target in requested!.toList()) {
            await onPublished(target);
          }
        });

        await makeResumePublish().exec(
          directory: d,
          ggLog: ggLog,
          resume: true,
          askBeforePublishing: false,
          message: 'm',
          versionIncrement: 'patch',
        );

        expect(requested, {PublishTarget.npm});
      });

      test('re-checks each registry after a legacy marker', () async {
        // An older gg could not say which registry it reached.
        await makeHybrid();
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        writeResumeFixture(doneSteps: ['prepare_version', 'publish_registry']);

        // Both registries already carry the un-bumped version, so the safety
        // net skips the upload without trusting the marker.
        when(
          () => publishedVersion.latestVersionFor(
            target: any(named: 'target'),
            directory: dMock(),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async => Version(1, 2, 3));

        await makeResumePublish().exec(
          directory: d,
          ggLog: ggLog,
          resume: true,
          askBeforePublishing: false,
          message: 'm',
          versionIncrement: 'patch',
        );

        expect(
          messages.join('\n'),
          contains('publish marker of an older gg version'),
        );
        verifyNever(
          () => publish.exec(
            directory: any<Directory>(named: 'directory'),
            ggLog: any<GgLog>(named: 'ggLog'),
            askBeforePublishing: any<bool>(named: 'askBeforePublishing'),
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        );
      });

      test('reconciles drifted versions and turns pana off', () async {
        // The ds_dna shape: the two manifests disagree.
        await makeHybrid(packageJsonVersion: '1.2.0');
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        // The same capture pattern the »--no-pana« tests use: stop right
        // after »can publish« received its options.
        late Map<String, dynamic> captured;
        final capturingCanPublish = MockCanPublish();
        when(
          () => capturingCanPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((invocation) async {
          captured =
              invocation.namedArguments[#options] as Map<String, dynamic>;
          throw Exception('stop');
        });

        await expectLater(
          DoPublish(
            upgradeDeps: upgradeDeps,
            waitUntilPublished: waitUntilPublished,
            ggLog: ggLog,
            publish: publish,
            canPublish: capturingCanPublish,
            configurePublish: makeConfigurePublish(),
            publishedVersion: publishedVersion,
            processWrapper: processWrapper,
            localBranch: localBranch,
            confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
            mergeFlow: noPubGetMergeFlow(),
          ).exec(
            directory: d,
            ggLog: ggLog,
            askBeforePublishing: false,
            deleteFeatureBranch: false,
            message: 'm',
            versionIncrement: 'patch',
          ),
          throwsA(isA<Exception>()),
        );

        final allMessages = messages.join('\n');
        expect(allMessages, contains('carried different versions'));
        expect(allMessages, contains('Publishing without pana'));
        // pana is turned off for this run.
        expect(captured[panaOption], isFalse);
        // Both manifests now carry the higher version.
        expect(
          File(join(d.path, 'package.json')).readAsStringSync(),
          contains('"version": "1.2.3"'),
        );
      });

      test('looks a prerelease up in the full version list', () async {
        // A prerelease never becomes a registry's »latest«, so the safety net
        // has to scan the whole list instead of comparing against latest.
        await makeHybrid(packageJsonVersion: '1.2.3');
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();

        writeResumeFixture(channel: 'rc', doneSteps: ['prepare_version']);
        // The bump already happened, so both manifests carry the rc.
        File(join(d.path, 'pubspec.yaml')).writeAsStringSync(
          File(join(d.path, 'pubspec.yaml'))
              .readAsStringSync()
              .replaceFirst('version: 1.2.3', 'version: 1.2.4-rc.1'),
        );
        File(
          join(d.path, 'package.json'),
        ).writeAsStringSync('{"name": "@org/test", "version": "1.2.4-rc.1"}');
        await Process.run('git', ['add', '.'], workingDirectory: d.path);
        await Process.run('git', [
          'commit',
          '-m',
          'Prepare the rc',
        ], workingDirectory: d.path);
        await makeLastStateSuccessful();
        messages.clear();

        // Both registries already carry the rc.
        when(
          () => publishedVersion.registryVersionsFor(
            target: any(named: 'target'),
            directory: dMock(),
          ),
        ).thenAnswer((_) async => [Version.parse('1.2.4-rc.1')]);

        await makeResumePublish().exec(
          directory: d,
          ggLog: ggLog,
          resume: true,
          askBeforePublishing: false,
          message: 'm',
          versionIncrement: 'patch',
          channel: 'rc',
        );

        // Nothing was uploaded — the rc is already on both registries.
        verifyNever(
          () => publish.exec(
            directory: any<Directory>(named: 'directory'),
            ggLog: any<GgLog>(named: 'ggLog'),
            askBeforePublishing: any<bool>(named: 'askBeforePublishing'),
            targets: any(named: 'targets'),
            onPublished: any(named: 'onPublished'),
          ),
        );
      });

      test('tolerates an already committed reconciliation', () async {
        // A resumed run finds the sync commit in place; committing nothing
        // must not abort the publish.
        await makeHybrid();
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        // Reports a change the working tree does not have.
        final phantomSync = MockSyncHybridVersions();
        when(
          () => phantomSync.apply(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async => (version: Version(1, 2, 3), changed: true));

        await DoPublish(
          upgradeDeps: upgradeDeps,
          syncHybridVersions: phantomSync,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          publish: publish,
          prepareNextVersion: PrepareNextVersion(
            ggLog: ggLog,
            publishedVersion: publishedVersion,
          ),
          canPublish: canPublish,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
          mergeFlow: noPubGetMergeFlow(),
        ).exec(
          directory: d,
          ggLog: ggLog,
          askBeforePublishing: false,
          deleteFeatureBranch: false,
          message: 'm',
          versionIncrement: 'patch',
        );

        expect(messages.join('\n'), contains('Publishing without pana'));
      });

      test('refuses to tag when the manifests still disagree', () async {
        // Defensive guard: normally the reconciliation makes this impossible,
        // so it is provoked by disabling the sync. Without it the release
        // would be tagged with one side's version and mislabel the other.
        await makeHybrid(packageJsonVersion: '9.9.9');
        publishedVersionValue = Version(1, 2, 3);
        mockPublishedVersion();
        mockPublishIsSuccessful(success: true, askBeforePublishing: false);

        stubGit(['rev-parse', '--verify', '--quiet', 'refs/heads/main']);
        stubGit(['checkout', 'main']);

        final noSync = MockSyncHybridVersions();
        when(
          () => noSync.apply(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async => null);

        writeResumeFixture(
          doneSteps: [
            'prepare_version',
            'publish_registry_pub_dev',
            'publish_registry_npm',
            'merge',
          ],
        );

        await expectLater(
          makeResumePublish(syncHybridVersions: noSync).exec(
            directory: d,
            ggLog: ggLog,
            resume: true,
            askBeforePublishing: false,
            message: 'm',
            versionIncrement: 'patch',
          ),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('refusing to tag the release'),
            ),
          ),
        );
      });
    });

    test('should have a code coverage of 100%', () {
      expect(
        DoPublish(
          upgradeDeps: upgradeDeps,
          waitUntilPublished: waitUntilPublished,
          ggLog: ggLog,
          configurePublish: makeConfigurePublish(),
          publishedVersion: publishedVersion,
          processWrapper: processWrapper,
          localBranch: localBranch,
          confirmDeleteFeatureBranch: defaultConfirmDeleteFeatureBranch,
        ),
        isNotNull,
      );
    });
  });
}

class MockGgProcessWrapper extends Mock implements GgProcessWrapper {}

class MockLocalBranch extends Mock implements LocalBranch {}

class _MockAddVersionTag extends Mock implements AddVersionTag {}
