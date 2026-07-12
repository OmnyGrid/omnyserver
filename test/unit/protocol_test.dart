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
