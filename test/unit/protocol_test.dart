@TestOn('vm')
library;

import 'package:omnyhub/omnyhub.dart' show BinaryMessage, TextMessage;
import 'package:omnyserver/omnyserver.dart';
import 'package:test/test.dart';

/// Round-trips [message] through the wire encoding, as the handshake would.
ControlMessage wireRoundTrip(ControlMessage message) {
  const codec = ControlMessageCodec.instance;
  return codec.fromWire(codec.toWire(message));
}

void main() {
  group('handshake messages', () {
    test('round-trips a Hello', () {
      final decoded =
          wireRoundTrip(
                Hello(
                  role: PeerRole.node,
                  protocolVersion: ProtocolVersion.current.label,
                  agentVersion: omnyServerVersion,
                ),
              )
              as Hello;

      expect(decoded.role, PeerRole.node);
      expect(decoded.protocolVersion, ProtocolVersion.current.label);
      expect(decoded.agentVersion, omnyServerVersion);
    });

    test('round-trips an AuthChallenge', () {
      final decoded =
          wireRoundTrip(const AuthChallenge('bm9uY2U=')) as AuthChallenge;
      expect(decoded.nonce, 'bm9uY2U=');
    });

    test('round-trips an AuthSubmit carrying a public-key credential', () {
      final decoded =
          wireRoundTrip(
                const AuthSubmit(
                  Credential(
                    principal: 'worker',
                    publicKey: 'cHVi',
                    signature: 'c2ln',
                  ),
                ),
              )
              as AuthSubmit;

      expect(decoded.credential.principal, 'worker');
      expect(decoded.credential.publicKey, 'cHVi');
      expect(decoded.credential.signature, 'c2ln');
      expect(decoded.credential.token, isNull);
    });

    test('round-trips an AuthOk with roles', () {
      final decoded =
          wireRoundTrip(const AuthOk(principalId: 'alice', roles: ['admin']))
              as AuthOk;

      expect(decoded.principalId, 'alice');
      expect(decoded.roles, ['admin']);
    });

    test('round-trips an AuthFail', () {
      expect(
        (wireRoundTrip(const AuthFail('bad key')) as AuthFail).reason,
        'bad key',
      );
    });

    test('round-trips a ProtocolErrorMessage', () {
      final decoded =
          wireRoundTrip(
                const ProtocolErrorMessage(
                  code: ErrorCodes.versionMismatch,
                  message: 'incompatible protocol version',
                ),
              )
              as ProtocolErrorMessage;

      expect(decoded.code, ErrorCodes.versionMismatch);
    });
  });

  group('the handshake codec rejects what it cannot trust', () {
    const codec = ControlMessageCodec.instance;

    test('an unknown type is a ProtocolException', () {
      expect(
        () => codec.decode({'type': 'no.such.message'}),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('malformed JSON is a ProtocolException', () {
      expect(
        () => codec.fromWire(const TextMessage('{not json')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a binary frame is a ProtocolException', () {
      // The handshake is strictly text JSON. A peer sending binary here is not
      // speaking our protocol and must be turned away, not tolerated.
      expect(
        () => codec.fromWire(BinaryMessage([0x00, 0x01])),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('operation payloads', () {
    test('a FormulaRun round-trips through its JSON payload', () {
      final decoded = FormulaRun.fromJson(
        const FormulaRun(
          requestId: 'r1',
          formula: 'docker',
          action: FormulaAction.install,
          version: '25.0',
          parameters: {'edition': 'ce'},
        ).toJson(),
      );

      expect(decoded.requestId, 'r1');
      expect(decoded.formula, 'docker');
      expect(decoded.action, FormulaAction.install);
      expect(decoded.version, '25.0');
      expect(decoded.parameters, {'edition': 'ce'});
    });

    test('a CommandRequest round-trips, args and all', () {
      final decoded = CommandRequest.fromJson(
        const CommandRequest(
          requestId: 'r1',
          command: 'systemctl',
          args: ['restart', 'nginx'],
        ).toJson(),
      );
      expect(decoded.command, 'systemctl');
      expect(decoded.args, ['restart', 'nginx']);

      // A command with no arguments is the common case, and must survive too.
      final bare = CommandRequest.fromJson(
        const CommandRequest(requestId: 'r2', command: 'uptime').toJson(),
      );
      expect(bare.args, isEmpty);
    });

    test('a FormulaRunResult carries the result it wraps', () {
      final result = FormulaResult(
        formula: 'docker',
        action: FormulaAction.install,
        success: true,
        changed: true,
        message: 'installed 24.0.7',
        finishedAt: DateTime.utc(2026, 6, 18, 12),
      );
      final decoded = FormulaRunResult.fromJson(
        FormulaRunResult(requestId: 'r1', result: result).toJson(),
      );
      expect(decoded.requestId, 'r1');
      expect(decoded.result.success, isTrue);
      expect(decoded.result.changed, isTrue);
      expect(decoded.result.message, 'installed 24.0.7');
    });

    test('a PresetApply carries the whole preset to the node', () {
      // The node is handed the preset itself, not an id to look up — it has no
      // Hub to ask.
      final decoded = PresetApply.fromJson(
        PresetApply(
          requestId: 'r1',
          preset: Preset(
            id: PresetId('docker-host'),
            name: 'Docker Host',
            steps: [
              PresetStep(formula: FormulaId('docker')),
              PresetStep(
                formula: FormulaId('git'),
                action: FormulaAction.verify,
              ),
            ],
          ),
        ).toJson(),
      );
      expect(decoded.preset.id, PresetId('docker-host'));
      expect(decoded.preset.steps, hasLength(2));
      expect(decoded.preset.steps.last.action, FormulaAction.verify);
    });

    test('a PresetApplyResult round-trips each step-s result', () {
      FormulaResult step(String formula, {required bool success}) =>
          FormulaResult(
            formula: formula,
            action: FormulaAction.install,
            success: success,
            finishedAt: DateTime.utc(2026, 6, 18, 12),
          );

      final decoded = PresetApplyResult.fromJson(
        PresetApplyResult(
          requestId: 'r1',
          success: false,
          results: [step('docker', success: true), step('git', success: false)],
        ).toJson(),
      );
      expect(decoded.success, isFalse);
      expect(decoded.results, hasLength(2));
      expect(decoded.results.last.success, isFalse);

      // A preset with no steps applied nothing, successfully.
      final empty = PresetApplyResult.fromJson(
        const PresetApplyResult(requestId: 'r2', success: true).toJson(),
      );
      expect(empty.results, isEmpty);
    });

    test('a ServiceControl and its result round-trip', () {
      final control = ServiceControl.fromJson(
        const ServiceControl(
          requestId: 'r1',
          service: 'nginx',
          action: 'restart',
        ).toJson(),
      );
      expect(control.service, 'nginx');
      expect(control.action, 'restart');

      final result = ServiceControlResult.fromJson(
        const ServiceControlResult(
          requestId: 'r1',
          success: true,
          descriptor: ServiceDescriptor(
            name: 'nginx',
            displayName: 'nginx',
            status: ServiceStatus.running,
          ),
          message: 'restarted',
        ).toJson(),
      );
      expect(result.success, isTrue);
      expect(result.descriptor?.status, ServiceStatus.running);
      expect(result.message, 'restarted');

      // A failure has no descriptor to report, and must not invent one.
      final failed = ServiceControlResult.fromJson(
        const ServiceControlResult(
          requestId: 'r1',
          success: false,
          message: 'no such service',
        ).toJson(),
      );
      expect(failed.descriptor, isNull);
      expect(failed.message, 'no such service');
    });

    test('a StatusReport round-trips the status it carries', () {
      final status = NodeStatus(
        capturedAt: DateTime.utc(2026, 6, 18, 12),
        cpu: const CpuInfo(usagePercent: 12.5, coreCount: 8),
        memory: const MemoryInfo(
          totalBytes: 8000,
          usedBytes: 2000,
          availableBytes: 6000,
        ),
        storage: const [],
        os: PlatformInfo.local(agentVersion: omnyServerVersion),
      );
      final decoded = StatusReport.fromJson(
        StatusReport(nodeId: 'worker-01', status: status).toJson(),
      );
      expect(decoded.nodeId, 'worker-01');
      expect(decoded.status.cpu.coreCount, 8);
      expect(decoded.status.cpu.usagePercent, 12.5);
    });

    test('a LogBatch round-trips, and defaults its source to the agent', () {
      final decoded = LogBatch.fromJson(
        const LogBatch(
          nodeId: 'worker-01',
          source: 'stderr',
          lines: ['one', 'two'],
        ).toJson(),
      );
      expect(decoded.source, 'stderr');
      expect(decoded.lines, ['one', 'two']);

      final bare = LogBatch.fromJson(
        const LogBatch(nodeId: 'worker-01').toJson(),
      );
      expect(bare.source, 'agent');
      expect(bare.lines, isEmpty);
    });

    test('a CommandResult round-trips, omitting empty streams', () {
      const result = CommandResult(requestId: 'r2', exitCode: 0, stdout: 'ok');
      expect(result.toJson().containsKey('stderr'), isFalse);

      final decoded = CommandResult.fromJson(result.toJson());
      expect(decoded.exitCode, 0);
      expect(decoded.stdout, 'ok');
      expect(decoded.stderr, '');
    });

    test('an OperationAck round-trips', () {
      final decoded = OperationAck.fromJson(
        const OperationAck(
          requestId: 'r3',
          success: false,
          message: 'refused',
        ).toJson(),
      );

      expect(decoded.success, isFalse);
      expect(decoded.message, 'refused');
    });

    test('a NodeControl round-trips its parameters', () {
      final decoded = NodeControl.fromJson(
        const NodeControl(
          requestId: 'r4',
          action: 'update',
          parameters: {'target': 'agent'},
        ).toJson(),
      );

      expect(decoded.action, 'update');
      expect(decoded.parameters['target'], 'agent');
    });

    test('the action names are the RPC vocabulary and must stay stable', () {
      // These strings are the wire contract between Hub and node: each is the
      // `action` on a NodeRequest or NodeNotify.
      expect(Operations.command, 'op.command.request');
      expect(Operations.formula, 'op.formula.run');
      expect(Operations.preset, 'op.preset.apply');
      expect(Operations.service, 'op.service.control');
      expect(Operations.control, 'op.node.control');
      expect(Operations.status, 'node.status');
      expect(Operations.logs, 'node.logs');
    });
  });

  group('protocol version', () {
    test('accepts a matching major', () {
      expect(
        ProtocolVersion.current.isCompatibleWith(
          ProtocolVersion.parse('${ProtocolVersion.current.major}.99'),
        ),
        isTrue,
      );
    });

    test('rejects a different major', () {
      expect(
        ProtocolVersion.current.isCompatibleWith(
          ProtocolVersion(ProtocolVersion.current.major + 1, 0),
        ),
        isFalse,
      );
    });
  });
}
