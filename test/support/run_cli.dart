import 'dart:async';

import 'package:omnyserver/omnyserver_cli.dart';

import 'captured_stdout.dart';

/// Runs the CLI with [args], returning what it printed and the exit code
/// *this* run set — 0 when it set none.
///
/// Read through [cliExitCodeZoneKey], never through `dart:io`'s `exitCode`:
/// that one is shared by every test file running in the process, and an
/// assertion on it can see another file's command.
Future<({String out, int code})> runCli(List<String> args) async {
  var code = 0;
  final out = await captureStdout(
    () => runZoned(
      () => buildRunner().run(args),
      zoneValues: {
        cliExitCodeZoneKey: (int c) {
          code = c;
        },
      },
    ),
  );
  return (out: out, code: code);
}
