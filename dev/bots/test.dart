// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:meta/meta.dart';

typedef Future<Null> ShardRunner();

final String flutterRoot = path.dirname(path.dirname(path.dirname(path.fromUri(Platform.script))));
final String flutter = path.join(flutterRoot, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');
final String dart = path.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', Platform.isWindows ? 'dart.exe' : 'dart');
final String pub = path.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', Platform.isWindows ? 'pub.bat' : 'pub');
final String pubCache = path.join(flutterRoot, '.pub-cache');
final List<String> flutterTestArgs = <String>[];
final bool hasColor = stdout.supportsAnsiEscapes;

final String bold = hasColor ? '\x1B[1m' : '';
final String red = hasColor ? '\x1B[31m' : '';
final String green = hasColor ? '\x1B[32m' : '';
final String yellow = hasColor ? '\x1B[33m' : '';
final String cyan = hasColor ? '\x1B[36m' : '';
final String reset = hasColor ? '\x1B[0m' : '';
const String arrow = '⏩';
const String clock = '🕐';

const Map<String, ShardRunner> _kShards = <String, ShardRunner>{
  'analyze': _analyzeRepo,
  'tests': _runTests,
  'tool_tests': _runToolTests,
  'coverage': _runCoverage,
  // 'docs': handled by travis_script.sh and docs.sh
  // 'build_and_deploy_gallery': handled by travis_script.sh
};

const Duration _kLongTimeout = Duration(minutes: 45);
const Duration _kShortTimeout = Duration(minutes: 5);

/// When you call this, you can pass additional arguments to pass custom
/// arguments to flutter test. For example, you might want to call this
/// script with the parameter --local-engine=host_debug_unopt to
/// use your own build of the engine.
///
/// To run the analysis part, run it with SHARD=analyze
///
/// For example:
/// SHARD=analyze bin/cache/dart-sdk/bin/dart dev/bots/test.dart
/// bin/cache/dart-sdk/bin/dart dev/bots/test.dart --local-engine=host_debug_unopt
Future<Null> main(List<String> args) async {
  flutterTestArgs.addAll(args);

  final String shard = Platform.environment['SHARD'];
  if (shard != null) {
    if (!_kShards.containsKey(shard)) {
      print('Invalid shard: $shard');
      print('The available shards are: ${_kShards.keys.join(", ")}');
      exit(1);
    }
    print('${bold}SHARD=$shard$reset');
    await _kShards[shard]();
  } else {
    for (String currentShard in _kShards.keys) {
      print('${bold}SHARD=$currentShard$reset');
      await _kShards[currentShard]();
      print('');
    }
  }
}

Future<Null> _verifyInternationalizations() async {
  final EvalResult genResult = await _evalCommand(
    dart,
    <String>[
      '--preview-dart-2',
      path.join('dev', 'tools', 'gen_localizations.dart'),
    ],
    workingDirectory: flutterRoot,
  );

  final String localizationsFile = path.join('packages', 'flutter_localizations', 'lib', 'src', 'l10n', 'localizations.dart');
  final String expectedResult = await new File(localizationsFile).readAsString();

  if (genResult.stdout.trim() != expectedResult.trim()) {
    stderr
      ..writeln('<<<<<<< $localizationsFile')
      ..writeln(expectedResult.trim())
      ..writeln('=======')
      ..writeln(genResult.stdout.trim())
      ..writeln('>>>>>>> gen_localizations')
      ..writeln('The contents of $localizationsFile are different from that produced by gen_localizations.')
      ..writeln()
      ..writeln('Did you forget to run gen_localizations.dart after updating a .arb file?');
    exit(1);
  }
  print('Contents of $localizationsFile matches output of gen_localizations.dart script.');
}

Future<String> _getCommitRange() async {
  // Using --fork-point is more conservative, and will result in the correct
  // fork point, but when running locally, it may return nothing. Git is
  // guaranteed to return a (reasonable, but maybe not optimal) result when not
  // using --fork-point, so we fall back to that if we can't get a definitive
  // fork point. See "git merge-base" documentation for more info.
  EvalResult result = await _evalCommand(
    'git',
    <String>['merge-base', '--fork-point', 'FETCH_HEAD', 'HEAD'],
    workingDirectory: flutterRoot,
    allowNonZeroExit: true,
  );
  if (result.exitCode != 0) {
    result = await _evalCommand(
      'git',
      <String>['merge-base', 'FETCH_HEAD', 'HEAD'],
      workingDirectory: flutterRoot,
    );
  }
  return result.stdout.trim();
}


Future<Null> _checkForTrailingSpaces() async {
  if (!Platform.isWindows) {
    final String commitRange = Platform.environment.containsKey('TEST_COMMIT_RANGE')
        ? Platform.environment['TEST_COMMIT_RANGE']
        : await _getCommitRange();
    final List<String> fileTypes = <String>[
      '*.dart', '*.cxx', '*.cpp', '*.cc', '*.c', '*.C', '*.h', '*.java', '*.mm', '*.m', '.yml',
    ];
    final EvalResult changedFilesResult = await _evalCommand(
      'git', <String>['diff', '-U0', '--no-color', '--name-only', commitRange, '--'] + fileTypes,
      workingDirectory: flutterRoot,
    );
    if (changedFilesResult.stdout == null) {
      print('No Results for whitespace check.');
      return;
    }
    // Only include files that actually exist, so that we don't try and grep for
    // nonexistent files (can occur when files are deleted or moved).
    final List<String> changedFiles = changedFilesResult.stdout.split('\n').where((String filename) {
      return new File(filename).existsSync();
    }).toList();
    if (changedFiles.isNotEmpty) {
      await _runCommand('grep',
        <String>[
          '--line-number',
          '--extended-regexp',
          r'[[:space:]]+$',
        ] + changedFiles,
        workingDirectory: flutterRoot,
        failureMessage: '${red}Whitespace detected at the end of source code lines.$reset\nPlease remove:',
        expectNonZeroExit: true, // Just means a non-zero exit code is expected.
        expectedExitCode: 1, // Indicates that zero lines were found.
      );
    }
  }
}

Future<Null> _analyzeRepo() async {
  await _verifyGeneratedPluginRegistrants(flutterRoot);
  await _verifyNoBadImportsInFlutter(flutterRoot);
  await _verifyNoBadImportsInFlutterTools(flutterRoot);
  await _verifyInternationalizations();

  // Analyze all the Dart code in the repo.
  await _runFlutterAnalyze(flutterRoot,
    options: <String>['--flutter-repo'],
  );

  // Ensure that all package dependencies are in sync.
  await _runCommand(flutter, <String>['update-packages', '--verify-only'],
    workingDirectory: flutterRoot,
  );

  // Analyze all the sample code in the repo
  await _runCommand(dart,
    <String>['--preview-dart-2', path.join(flutterRoot, 'dev', 'bots', 'analyze-sample-code.dart')],
    workingDirectory: flutterRoot,
  );

  // Try with the --watch analyzer, to make sure it returns success also.
  // The --benchmark argument exits after one run.
  await _runFlutterAnalyze(flutterRoot,
    options: <String>['--flutter-repo', '--watch', '--benchmark'],
  );

  await _checkForTrailingSpaces();

  // Try an analysis against a big version of the gallery.
  await _runCommand(dart,
    <String>['--preview-dart-2', path.join(flutterRoot, 'dev', 'tools', 'mega_gallery.dart')],
    workingDirectory: flutterRoot,
  );
  await _runFlutterAnalyze(path.join(flutterRoot, 'dev', 'benchmarks', 'mega_gallery'),
    options: <String>['--watch', '--benchmark'],
  );

  print('${bold}DONE: Analysis successful.$reset');
}

Future<Null> _runSmokeTests() async {
  // Verify that the tests actually return failure on failure and success on
  // success.
  final String automatedTests = path.join(flutterRoot, 'dev', 'automated_tests');
  // We run the "pass" and "fail" smoke tests first, and alone, because those
  // are particularly critical and sensitive. If one of these fails, there's no
  // point even trying the others.
  await _runFlutterTest(automatedTests,
    script: path.join('test_smoke_test', 'pass_test.dart'),
    printOutput: false,
    timeout: _kShortTimeout,
  );
  await _runFlutterTest(automatedTests,
    script: path.join('test_smoke_test', 'fail_test.dart'),
    expectFailure: true,
    printOutput: false,
    timeout: _kShortTimeout,
  );
  // We run the timeout tests individually because they are timing-sensitive.
  await _runFlutterTest(automatedTests,
    script: path.join('test_smoke_test', 'timeout_pass_test.dart'),
    expectFailure: false,
    printOutput: false,
    timeout: _kShortTimeout,
  );
  await _runFlutterTest(automatedTests,
    script: path.join('test_smoke_test', 'timeout_fail_test.dart'),
    expectFailure: true,
    printOutput: false,
    timeout: _kShortTimeout,
  );
  // We run the remaining smoketests in parallel, because they each take some
  // time to run (e.g. compiling), so we don't want to run them in series,
  // especially on 20-core machines...
  await Future.wait<void>(
    <Future<void>>[
      _runFlutterTest(automatedTests,
        script: path.join('test_smoke_test', 'crash1_test.dart'),
        expectFailure: true,
        printOutput: false,
        timeout: _kShortTimeout,
      ),
      _runFlutterTest(automatedTests,
        script: path.join('test_smoke_test', 'crash2_test.dart'),
        expectFailure: true,
        printOutput: false,
        timeout: _kShortTimeout,
      ),
      _runFlutterTest(automatedTests,
        script: path.join('test_smoke_test', 'syntax_error_test.broken_dart'),
        expectFailure: true,
        printOutput: false,
        timeout: _kShortTimeout,
      ),
      _runFlutterTest(automatedTests,
        script: path.join('test_smoke_test', 'missing_import_test.broken_dart'),
        expectFailure: true,
        printOutput: false,
        timeout: _kShortTimeout,
      ),
      _runFlutterTest(automatedTests,
        script: path.join('test_smoke_test', 'disallow_error_reporter_modification_test.dart'),
        expectFailure: true,
        printOutput: false,
        timeout: _kShortTimeout,
      ),
      _runCommand(flutter,
        <String>['drive', '--use-existing-app', '-t', path.join('test_driver', 'failure.dart')],
        workingDirectory: path.join(flutterRoot, 'packages', 'flutter_driver'),
        expectNonZeroExit: true,
        printOutput: false,
        timeout: _kShortTimeout,
      ),
    ],
  );

  // Verify that we correctly generated the version file.
  await _verifyVersion(path.join(flutterRoot, 'version'));
}

Future<Null> _runToolTests() async {
  await _runSmokeTests();

  await _pubRunTest(path.join(flutterRoot, 'packages', 'flutter_tools'));

  print('${bold}DONE: All tests successful.$reset');
}

Future<Null> _runTests() async {
  await _runSmokeTests();

  await _runFlutterTest(path.join(flutterRoot, 'packages', 'flutter'));
  await _runFlutterTest(path.join(flutterRoot, 'packages', 'flutter_localizations'));
  await _runFlutterTest(path.join(flutterRoot, 'packages', 'flutter_driver'));
  await _runFlutterTest(path.join(flutterRoot, 'packages', 'flutter_test'));
  await _runFlutterTest(path.join(flutterRoot, 'packages', 'fuchsia_remote_debug_protocol'));
  await _pubRunTest(path.join(flutterRoot, 'dev', 'bots'));
  await _pubRunTest(path.join(flutterRoot, 'dev', 'devicelab'));
  await _runFlutterTest(path.join(flutterRoot, 'dev', 'manual_tests'));
  await _runFlutterTest(path.join(flutterRoot, 'dev', 'tools', 'vitool'));
  await _runFlutterTest(path.join(flutterRoot, 'examples', 'hello_world'));
  await _runFlutterTest(path.join(flutterRoot, 'examples', 'layers'));
  await _runFlutterTest(path.join(flutterRoot, 'examples', 'stocks'));
  await _runFlutterTest(path.join(flutterRoot, 'examples', 'flutter_gallery'));
  await _runFlutterTest(path.join(flutterRoot, 'examples', 'catalog'));

  print('${bold}DONE: All tests successful.$reset');
}

Future<Null> _runCoverage() async {
  final File coverageFile = new File(path.join(flutterRoot, 'packages', 'flutter', 'coverage', 'lcov.info'));
  if (!coverageFile.existsSync()) {
    print('${red}Coverage file not found.$reset');
    print('Expected to find: ${coverageFile.absolute}');
    print('This file is normally obtained by running `flutter update-packages`.');
    exit(1);
  }
  coverageFile.deleteSync();
  await _runFlutterTest(path.join(flutterRoot, 'packages', 'flutter'),
    options: const <String>['--coverage'],
  );
  if (!coverageFile.existsSync()) {
    print('${red}Coverage file not found.$reset');
    print('Expected to find: ${coverageFile.absolute}');
    print('This file should have been generated by the `flutter test --coverage` script, but was not.');
    exit(1);
  }

  print('${bold}DONE: Coverage collection successful.$reset');
}

Future<Null> _pubRunTest(
  String workingDirectory, {
  String testPath,
}) {
  final List<String> args = <String>['run', 'test', '-j1', '-rcompact'];
  if (!hasColor)
    args.add('--no-color');
  if (testPath != null)
    args.add(testPath);
  final Map<String, String> pubEnvironment = <String, String>{};
  if (new Directory(pubCache).existsSync()) {
    pubEnvironment['PUB_CACHE'] = pubCache;
  }
  return _runCommand(
    pub, args,
    workingDirectory: workingDirectory,
    environment: pubEnvironment,
  );
}

class EvalResult {
  EvalResult({
    this.stdout,
    this.stderr,
    this.exitCode = 0,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
}

Future<EvalResult> _evalCommand(String executable, List<String> arguments, {
  @required String workingDirectory,
  Map<String, String> environment,
  bool skip = false,
  bool allowNonZeroExit = false,
}) async {
  final String commandDescription = '${path.relative(executable, from: workingDirectory)} ${arguments.join(' ')}';
  final String relativeWorkingDir = path.relative(workingDirectory);
  if (skip) {
    _printProgress('SKIPPING', relativeWorkingDir, commandDescription);
    return null;
  }
  _printProgress('RUNNING', relativeWorkingDir, commandDescription);

  final DateTime start = new DateTime.now();
  final Process process = await Process.start(executable, arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  final Future<List<List<int>>> savedStdout = process.stdout.toList();
  final Future<List<List<int>>> savedStderr = process.stderr.toList();
  final int exitCode = await process.exitCode;
  final EvalResult result = new EvalResult(
    stdout: utf8.decode((await savedStdout).expand((List<int> ints) => ints).toList()),
    stderr: utf8.decode((await savedStderr).expand((List<int> ints) => ints).toList()),
    exitCode: exitCode,
  );

  print('$clock ELAPSED TIME: $bold${elapsedTime(start)}$reset for $commandDescription in $relativeWorkingDir: ');

  if (exitCode != 0 && !allowNonZeroExit) {
    stderr.write(result.stderr);
    print(
      '$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset\n'
      '${bold}ERROR:$red Last command exited with $exitCode.$reset\n'
      '${bold}Command:$red $commandDescription$reset\n'
      '${bold}Relative working directory:$red $relativeWorkingDir$reset\n'
      '$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset'
    );
    exit(1);
  }

  return result;
}

String elapsedTime(DateTime start) {
  return new DateTime.now().difference(start).toString();
}

Future<Null> _runCommand(String executable, List<String> arguments, {
  String workingDirectory,
  Map<String, String> environment,
  bool expectNonZeroExit = false,
  int expectedExitCode,
  String failureMessage,
  bool printOutput = true,
  bool skip = false,
  Duration timeout = _kLongTimeout,
}) async {
  final String commandDescription = '${path.relative(executable, from: workingDirectory)} ${arguments.join(' ')}';
  final String relativeWorkingDir = path.relative(workingDirectory);
  if (skip) {
    _printProgress('SKIPPING', relativeWorkingDir, commandDescription);
    return null;
  }
  _printProgress('RUNNING', relativeWorkingDir, commandDescription);

  final DateTime start = new DateTime.now();
  final Process process = await Process.start(executable, arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  Future<List<List<int>>> savedStdout, savedStderr;
  if (printOutput) {
    await Future.wait(<Future<void>>[
      stdout.addStream(process.stdout),
      stderr.addStream(process.stderr)
    ]);
  } else {
    savedStdout = process.stdout.toList();
    savedStderr = process.stderr.toList();
  }

  final int exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
    stderr.writeln('Process timed out after $timeout');
    return expectNonZeroExit ? 0 : 1;
  });
  print('$clock ELAPSED TIME: $bold${elapsedTime(start)}$reset for $commandDescription in $relativeWorkingDir: ');
  if ((exitCode == 0) == expectNonZeroExit || (expectedExitCode != null && exitCode != expectedExitCode)) {
    if (failureMessage != null) {
      print(failureMessage);
    }
    if (!printOutput) {
      stdout.writeln(utf8.decode((await savedStdout).expand((List<int> ints) => ints).toList()));
      stderr.writeln(utf8.decode((await savedStderr).expand((List<int> ints) => ints).toList()));
    }
    print(
      '$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset\n'
      '${bold}ERROR:$red Last command exited with $exitCode (expected: ${expectNonZeroExit ? (expectedExitCode ?? 'non-zero') : 'zero'}).$reset\n'
      '${bold}Command:$cyan $commandDescription$reset\n'
      '${bold}Relative working directory:$red $relativeWorkingDir$reset\n'
      '$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset'
    );
    exit(1);
  }
}

Future<Null> _runFlutterTest(String workingDirectory, {
  String script,
  bool expectFailure = false,
  bool printOutput = true,
  List<String> options = const <String>[],
  bool skip = false,
  Duration timeout = _kLongTimeout,
}) {
  final List<String> args = <String>['test']..addAll(options);
  if (flutterTestArgs != null && flutterTestArgs.isNotEmpty)
    args.addAll(flutterTestArgs);
  if (script != null) {
    final String fullScriptPath = path.join(workingDirectory, script);
    if (!FileSystemEntity.isFileSync(fullScriptPath)) {
      print('Could not find test: $fullScriptPath');
      print('Working directory: $workingDirectory');
      print('Script: $script');
      if (!printOutput)
        print('This is one of the tests that does not normally print output.');
      if (skip)
        print('This is one of the tests that is normally skipped in this configuration.');
      exit(1);
    }
    args.add(script);
  }
  return _runCommand(flutter, args,
    workingDirectory: workingDirectory,
    expectNonZeroExit: expectFailure,
    printOutput: printOutput,
    skip: skip,
    timeout: timeout,
  );
}

Future<Null> _runFlutterAnalyze(String workingDirectory, {
  List<String> options = const <String>[]
}) {
  return _runCommand(flutter, <String>['analyze']..addAll(options),
    workingDirectory: workingDirectory,
  );
}

Future<Null> _verifyNoBadImportsInFlutter(String workingDirectory) async {
  final List<String> errors = <String>[];
  final String libPath = path.join(workingDirectory, 'packages', 'flutter', 'lib');
  final String srcPath = path.join(workingDirectory, 'packages', 'flutter', 'lib', 'src');
  // Verify there's one libPath/*.dart for each srcPath/*/.
  final List<String> packages = new Directory(libPath).listSync()
    .where((FileSystemEntity entity) => entity is File && path.extension(entity.path) == '.dart')
    .map<String>((FileSystemEntity entity) => path.basenameWithoutExtension(entity.path))
    .toList()..sort();
  final List<String> directories = new Directory(srcPath).listSync()
    .where((FileSystemEntity entity) => entity is Directory)
    .map<String>((FileSystemEntity entity) => path.basename(entity.path))
    .toList()..sort();
  if (!_matches(packages, directories)) {
    errors.add(
      'flutter/lib/*.dart does not match flutter/lib/src/*/:\n'
      'These are the exported packages:\n' +
      packages.map((String path) => '  lib/$path.dart').join('\n') +
      'These are the directories:\n' +
      directories.map((String path) => '  lib/src/$path/').join('\n')
    );
  }
  // Verify that the imports are well-ordered.
  final Map<String, Set<String>> dependencyMap = <String, Set<String>>{};
  for (String directory in directories) {
    dependencyMap[directory] = _findDependencies(path.join(srcPath, directory), errors, checkForMeta: directory != 'foundation');
  }
  for (String package in dependencyMap.keys) {
    if (dependencyMap[package].contains(package)) {
      errors.add(
        'One of the files in the $yellow$package$reset package imports that package recursively.'
      );
    }
  }
  for (String package in dependencyMap.keys) {
    final List<String> loop = _deepSearch(dependencyMap, package);
    if (loop != null) {
      errors.add(
        '${yellow}Dependency loop:$reset ' +
        loop.join(' depends on ')
      );
    }
  }
  // Fail if any errors
  if (errors.isNotEmpty) {
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    if (errors.length == 1) {
      print('${bold}An error was detected when looking at import dependencies within the Flutter package:$reset\n');
    } else {
      print('${bold}Multiple errors were detected when looking at import dependencies within the Flutter package:$reset\n');
    }
    print(errors.join('\n\n'));
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset\n');
    exit(1);
  }
}

bool _matches<T>(List<T> a, List<T> b) {
  assert(a != null);
  assert(b != null);
  if (a.length != b.length)
    return false;
  for (int index = 0; index < a.length; index += 1) {
    if (a[index] != b[index])
      return false;
  }
  return true;
}

final RegExp _importPattern = new RegExp(r"import 'package:flutter/([^.]+)\.dart'");
final RegExp _importMetaPattern = new RegExp(r"import 'package:meta/meta.dart'");

Set<String> _findDependencies(String srcPath, List<String> errors, { bool checkForMeta = false }) {
  return new Directory(srcPath).listSync(recursive: true).where((FileSystemEntity entity) {
    return entity is File && path.extension(entity.path) == '.dart';
  }).map<Set<String>>((FileSystemEntity entity) {
    final Set<String> result = new Set<String>();
    final File file = entity;
    for (String line in file.readAsLinesSync()) {
      Match match = _importPattern.firstMatch(line);
      if (match != null)
        result.add(match.group(1));
      if (checkForMeta) {
        match = _importMetaPattern.firstMatch(line);
        if (match != null) {
          errors.add(
            '${file.path}\nThis package imports the ${yellow}meta$reset package.\n'
            'You should instead import the "foundation.dart" library.'
          );
        }
      }
    }
    return result;
  }).reduce((Set<String> value, Set<String> element) {
    value ??= new Set<String>();
    value.addAll(element);
    return value;
  });
}

List<T> _deepSearch<T>(Map<T, Set<T>> map, T start, [ Set<T> seen ]) {
  for (T key in map[start]) {
    if (key == start)
      continue; // we catch these separately
    if (seen != null && seen.contains(key))
      return <T>[start, key];
    final List<T> result = _deepSearch(
      map,
      key,
      (seen == null ? new Set<T>.from(<T>[start]) : new Set<T>.from(seen))..add(key),
    );
    if (result != null) {
      result.insert(0, start);
      // Only report the shortest chains.
      // For example a->b->a, rather than c->a->b->a.
      // Since we visit every node, we know the shortest chains are those
      // that start and end on the loop.
      if (result.first == result.last)
        return result;
    }
  }
  return null;
}

Future<Null> _verifyNoBadImportsInFlutterTools(String workingDirectory) async {
  final List<String> errors = <String>[];
  for (FileSystemEntity entity in new Directory(path.join(workingDirectory, 'packages', 'flutter_tools', 'lib'))
    .listSync(recursive: true)
    .where((FileSystemEntity entity) => entity is File && path.extension(entity.path) == '.dart')) {
    final File file = entity;
    if (file.readAsStringSync().contains('package:flutter_tools/')) {
      errors.add('$yellow${file.path}$reset imports flutter_tools.');
    }
  }
  // Fail if any errors
  if (errors.isNotEmpty) {
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    if (errors.length == 1) {
      print('${bold}An error was detected when looking at import dependencies within the flutter_tools package:$reset\n');
    } else {
      print('${bold}Multiple errors were detected when looking at import dependencies within the flutter_tools package:$reset\n');
    }
    print(errors.join('\n\n'));
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset\n');
    exit(1);
  }
}

void _printProgress(String action, String workingDir, String command) {
  print('$arrow $action: cd $cyan$workingDir$reset; $yellow$command$reset');
}

Future<Null> _verifyGeneratedPluginRegistrants(String flutterRoot) async {
  final Directory flutterRootDir = new Directory(flutterRoot);

  final Map<String, List<File>> packageToRegistrants = <String, List<File>>{};

  for (FileSystemEntity entity in flutterRootDir.listSync(recursive: true)) {
    if (entity is! File)
      continue;
    if (_isGeneratedPluginRegistrant(entity)) {
      final String package = _getPackageFor(entity, flutterRootDir);
      final List<File> registrants = packageToRegistrants.putIfAbsent(package, () => <File>[]);
      registrants.add(entity);
    }
  }

  final Set<String> outOfDate = new Set<String>();

  for (String package in packageToRegistrants.keys) {
    final Map<File, String> fileToContent = <File, String>{};
    for (File f in packageToRegistrants[package]) {
      fileToContent[f] = f.readAsStringSync();
    }
    await _runCommand(flutter, <String>['inject-plugins'],
      workingDirectory: package,
      printOutput: false,
    );
    for (File registrant in fileToContent.keys) {
      if (registrant.readAsStringSync() != fileToContent[registrant]) {
        outOfDate.add(registrant.path);
      }
    }
  }

  if (outOfDate.isNotEmpty) {
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    print('${bold}The following GeneratedPluginRegistrants are out of date:$reset');
    for (String registrant in outOfDate) {
      print(' - $registrant');
    }
    print('\nRun "flutter inject-plugins" in the package that\'s out of date.');
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    exit(1);
  }
}

String _getPackageFor(File entity, Directory flutterRootDir) {
  for (Directory dir = entity.parent; dir != flutterRootDir; dir = dir.parent) {
    if (new File(path.join(dir.path, 'pubspec.yaml')).existsSync()) {
      return dir.path;
    }
  }
  throw new ArgumentError('$entity is not within a dart package.');
}

bool _isGeneratedPluginRegistrant(File file) {
  final String filename = path.basename(file.path);
  return !file.path.contains('.pub-cache')
      && (filename == 'GeneratedPluginRegistrant.java' ||
          filename == 'GeneratedPluginRegistrant.h' ||
          filename == 'GeneratedPluginRegistrant.m');
}

Future<Null> _verifyVersion(String filename) async {
  if (!new File(filename).existsSync()) {
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    print('The version logic failed to create the Flutter version file.');
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    exit(1);
  }
  final String version = await new File(filename).readAsString();
  if (version == '0.0.0-unknown') {
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    print('The version logic failed to determine the Flutter version.');
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    exit(1);
  }
  final RegExp pattern = new RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+(-pre\.[0-9]+)?$');
  if (!version.contains(pattern)) {
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    print('The version logic generated an invalid version string.');
    print('$red━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$reset');
    exit(1);
  }
}
