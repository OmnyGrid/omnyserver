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

    test('an action nobody implements is refused, not acknowledged', () async {
      final service = UpdateService(executor: _RecordingExecutor());
      final (ok, message) = await service.handle(
        const NodeControl(requestId: 'r', action: 'teleport'),
      );
      expect(ok, isFalse);
      expect(message, contains('unknown node control action "teleport"'));
    });
  });

  // These act on *the agent*, never on the machine it runs on — and until they
  // did anything at all, they reported success anyway: `restart` and
  // `shutdown` were acknowledged and dropped, so an operator watched a green
  // result and an untouched node.
  group('UpdateService stopping the agent', () {
    test('restart stops the agent, and says it is the agent', () async {
      var restarted = 0;
      final service = UpdateService(
        executor: _RecordingExecutor(),
        onRestartAgent: () async => restarted++,
      );

      final (ok, message) = await service.handle(
        const NodeControl(requestId: 'r', action: 'restart'),
      );
      expect(ok, isTrue);
      expect(message, contains('agent'));

      // Answered first, acted on after: the reply travels over the connection
      // the agent is about to close.
      expect(restarted, 0, reason: 'not before the answer is on its way');
      await Future<void>.delayed(UpdateService.replyGrace * 3);
      expect(restarted, 1);
    });

    test('shutdown stops the agent', () async {
      var stopped = 0;
      final service = UpdateService(
        executor: _RecordingExecutor(),
        onStopAgent: () async => stopped++,
      );

      final (ok, message) = await service.handle(
        const NodeControl(requestId: 'r', action: 'shutdown'),
      );
      expect(ok, isTrue);
      expect(message, contains('agent'));

      await Future<void>.delayed(UpdateService.replyGrace * 3);
      expect(stopped, 1);
    });

    test(
      'the two are wired separately, so one cannot answer for the other',
      () async {
        // A restart that silently shut the node down for good would be the worst
        // possible confusion between these.
        var restarted = 0;
        var stopped = 0;
        final service = UpdateService(
          executor: _RecordingExecutor(),
          onRestartAgent: () async => restarted++,
          onStopAgent: () async => stopped++,
        );

        await service.handle(
          const NodeControl(requestId: 'r', action: 'restart'),
        );
        await Future<void>.delayed(UpdateService.replyGrace * 3);
        expect((restarted, stopped), (1, 0));

        await service.handle(
          const NodeControl(requestId: 'r', action: 'shutdown'),
        );
        await Future<void>.delayed(UpdateService.replyGrace * 3);
        expect((restarted, stopped), (1, 1));
      },
    );

    test('an agent with no way to stop itself says so', () async {
      // The failure that matters: reporting success for work not done is worse
      // than reporting that it cannot be done.
      final service = UpdateService(executor: _RecordingExecutor());

      for (final action in ['restart', 'shutdown']) {
        final (ok, message) = await service.handle(
          NodeControl(requestId: 'r', action: action),
        );
        expect(ok, isFalse, reason: action);
        expect(message, contains('without a way to stop itself'));
      }
    });

    test('a restart exits non-zero, so a supervisor brings the agent back', () {
      // The whole mechanism: `Restart=on-failure` (and Docker's
      // `restart: on-failure`) restart a non-zero exit and honour a clean one,
      // which is what makes shutdown stick and restart return.
      expect(agentRestartExitCode, isNot(0));
    });
  });
}
