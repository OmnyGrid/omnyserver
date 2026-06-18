@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:omnyserver/omnyserver.dart';
import 'package:test/test.dart';

import '../support/loopback_connection.dart';

void main() {
  const codec = FrameCodec.standard;

  group('FrameCodec control messages', () {
    test('round-trips a Hello', () {
      final frame = ControlFrame(
        Hello(
          role: PeerRole.node,
          protocolVersion: ProtocolVersion.current.label,
          agentVersion: omnyServerVersion,
          uid: 'deadbeef',
        ),
      );
      final wire = codec.encode(frame);
      expect(wire, isA<String>());
      final back = codec.decode(wire);
      expect(back, isA<ControlFrame>());
      final msg = (back as ControlFrame).message;
      expect(msg, isA<Hello>());
      expect((msg as Hello).role, PeerRole.node);
      expect(msg.uid, 'deadbeef');
    });

    test('round-trips an AuthSubmit credential', () {
      final frame = ControlFrame(
        AuthSubmit(const Credential.token(principal: 'alice', token: 's3cr3t')),
      );
      final back = codec.decode(codec.encode(frame)) as ControlFrame;
      final submit = back.message as AuthSubmit;
      expect(submit.credential.principal, 'alice');
      expect(submit.credential.token, 's3cr3t');
    });

    test('unknown message type throws ProtocolException', () {
      expect(
        () => codec.decode('{"type":"nope"}'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('invalid JSON throws ProtocolException', () {
      expect(() => codec.decode('not json'), throwsA(isA<ProtocolException>()));
    });
  });

  group('FrameCodec data frames', () {
    test('round-trips a binary data frame', () {
      final payload = Uint8List.fromList([10, 20, 30, 40]);
      final frame = DataFrame(
        channel: 7,
        opcode: DataOpcode.log,
        payload: payload,
      );
      final wire = codec.encode(frame);
      expect(wire, isA<Uint8List>());
      final back = codec.decode(wire) as DataFrame;
      expect(back.channel, 7);
      expect(back.opcode, DataOpcode.log);
      expect(back.payload, payload);
    });
  });

  group('LoopbackPair', () {
    test('delivers messages both directions', () async {
      final pair = LoopbackPair();
      final aSeen = <ControlMessage>[];
      final bSeen = <ControlMessage>[];
      pair.a.incoming.listen((f) {
        if (f is ControlFrame) aSeen.add(f.message);
      });
      pair.b.incoming.listen((f) {
        if (f is ControlFrame) bSeen.add(f.message);
      });

      pair.a.sendMessage(const Ping('p1'));
      pair.b.sendMessage(const Pong('p1'));
      await Future<void>.delayed(Duration.zero);

      expect(bSeen.single, isA<Ping>());
      expect(aSeen.single, isA<Pong>());
      await pair.a.close();
      await pair.b.close();
    });
  });
}
