@TestOn('vm')
library;

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

    test('os update runs the platform command', () async {
      final exec = _RecordingExecutor();
      final service = UpdateService(executor: exec);
      final (ok, _) = await service.handle(
        const NodeControl(
          requestId: 'r',
          action: 'update',
          parameters: {'target': 'os'},
        ),
      );
      expect(ok, isTrue);
      expect(exec.calls, isNotEmpty);
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
