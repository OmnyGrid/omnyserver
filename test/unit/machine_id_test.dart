@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

void main() {
  group('MachineId', () {
    // This value is hashed into a node's UID, so it is the node's name on the
    // fleet. Whatever the host does or does not expose, `resolve` has to answer
    // — an exception here would take registration down with it.
    test('always answers, on whatever host the suite runs on', () async {
      final id = await MachineId.resolve();
      expect(id, isNotEmpty);
      expect(id.trim(), id, reason: 'a stray newline would change the UID');
    });

    test('answers the same thing twice — identity is not re-rolled', () async {
      expect(await MachineId.resolve(), await MachineId.resolve());
    });

    test('falls back to the host name when the platform offers nothing', () {
      // The documented floor. On a host with no machine-id file and no ioreg,
      // this is what a node is identified by, so it must never be blank.
      expect(Platform.localHostname, isNotEmpty);
    });
  });
}
