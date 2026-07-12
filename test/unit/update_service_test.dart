@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

class _RecordingExecutor implements CommandExecutor {
  final List<String> calls = [];
  static const ExecResult result = ExecResult(exitCode: 0, stdout: 'ok');

  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    calls.add('$executable ${args.join(' ')}');
    return result;
  }
}

void main() {
  group('UpdateService', () {
    test(
      'agent self-update is acknowledged without running commands',
      () async {
        final exec = _RecordingExecutor();
        final service = UpdateService(executor: exec);
        final (ok, message) = await service.handle(
          const NodeControl(
            requestId: 'r',
            action: 'update',
            parameters: {'target': 'agent'},
          ),
        );
        expect(ok, isTrue);
        expect(message, contains('self-update'));
        expect(exec.calls, isEmpty);
      },
    );

    test('os update runs the platform command where one exists', () async {
      final exec = _RecordingExecutor();
      final service = UpdateService(executor: exec);
      final (ok, message) = await service.handle(
        const NodeControl(
          requestId: 'r',
          action: 'update',
          parameters: {'target': 'os'},
        ),
      );

      // `UpdateService` only knows a package manager for Linux (apt) and macOS
      // (softwareupdate). On anything else it must refuse cleanly rather than
      // run something arbitrary — a node that cannot patch itself has to say so.
      if (Platform.isLinux || Platform.isMacOS) {
        expect(ok, isTrue);
        expect(exec.calls, isNotEmpty);
      } else {
        expect(ok, isFalse);
        expect(message, contains('not supported'));
        expect(exec.calls, isEmpty);
      }
    });

    test('non-update actions are acknowledged', () async {
      final service = UpdateService(executor: _RecordingExecutor());
      final (ok, message) = await service.handle(
        const NodeControl(requestId: 'r', action: 'restart'),
      );
      expect(ok, isTrue);
      expect(message, contains('restart'));
    });
  });
}
