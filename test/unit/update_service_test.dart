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

/// An executor whose commands always fail, with [stderr] as the reason.
class _FailingExecutor implements CommandExecutor {
  final String stderr;

  _FailingExecutor(this.stderr);

  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async => ExecResult(exitCode: 100, stderr: '$stderr\n');
}

void main() {
  group('ProcessCommandExecutor', () {
    test('captures stdout and the exit code of a real command', () async {
      const executor = ProcessCommandExecutor();
      final result = await executor.run('echo', const ['hello']);

      expect(result.ok, isTrue);
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'hello');
    });

    test('a non-zero exit is a result, with its stderr', () async {
      const executor = ProcessCommandExecutor();
      final result = await executor.run('sh', const [
        '-c',
        'echo nope >&2; exit 2',
      ]);

      expect(result.ok, isFalse);
      expect(result.exitCode, 2);
      expect(result.stderr.trim(), 'nope');
    });

    test('an executable that is not there comes back as 127', () async {
      const executor = ProcessCommandExecutor();
      // A formula probing for a tool that is absent is the common case, and it
      // must read as "not installed", not as a crash partway through a run.
      final result = await executor.run('definitely-not-a-real-binary-xyz', []);

      expect(result.ok, isFalse);
      expect(result.exitCode, 127);
      expect(result.stderr, isNotEmpty);
    });

    test('the environment is passed through to the command', () async {
      const executor = ProcessCommandExecutor();
      final result = await executor.run(
        'sh',
        const ['-c', r'printf %s "$OMNY_TEST_VAR"'],
        environment: const {'OMNY_TEST_VAR': 'passed-through'},
      );

      expect(result.stdout, 'passed-through');
    });
  }, testOn: '!windows');

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

    test('a named target is a package update, not an OS update', () async {
      final exec = _RecordingExecutor();
      final service = UpdateService(executor: exec);
      final (ok, message) = await service.handle(
        const NodeControl(
          requestId: 'r',
          action: 'update',
          parameters: {'target': 'curl'},
        ),
      );

      if (Platform.isLinux || Platform.isMacOS) {
        expect(ok, isTrue);
        expect(message, contains('updated curl'));
        // The package is named in the command, so it upgrades that one thing
        // rather than everything the machine has.
        expect(exec.calls.single, contains('curl'));
      } else {
        expect(ok, isFalse);
        expect(message, contains('not supported'));
        expect(exec.calls, isEmpty);
      }
    });

    test('a failed package update reports the command-s own stderr', () async {
      final exec = _FailingExecutor('E: Unable to locate package nosuchpkg');
      final service = UpdateService(executor: exec);
      final (ok, message) = await service.handle(
        const NodeControl(
          requestId: 'r',
          action: 'update',
          parameters: {'target': 'nosuchpkg'},
        ),
      );

      expect(ok, isFalse);
      if (Platform.isLinux || Platform.isMacOS) {
        // The package manager's reason, not a generic "update failed" — that
        // reason is the only thing that tells an operator what to do next.
        expect(message, contains('Unable to locate package'));
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
