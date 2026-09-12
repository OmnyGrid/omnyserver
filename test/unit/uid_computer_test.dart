@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

/// The identity material of one host, so a test can vary a single field.
OmnyUid _node({
  Uint8List? publicKey,
  String machineId = 'machine-aaaa',
  String os = 'linux',
  String arch = 'x64',
  String hostname = 'edge-01',
}) => UidComputer.computeNodeUid(
  publicKey: publicKey,
  machineId: machineId,
  os: os,
  arch: arch,
  hostname: hostname,
);

OmnyUid _hub({
  Uint8List? keyMaterial,
  String machineId = 'machine-aaaa',
  String os = 'linux',
  String arch = 'x64',
  String hostname = 'edge-01',
}) => UidComputer.computeHubUid(
  keyMaterial: keyMaterial ?? Uint8List(0),
  machineId: machineId,
  os: os,
  arch: arch,
  hostname: hostname,
);

void main() {
  group('UidComputer', () {
    test('is deterministic — the same host is the same identity', () {
      expect(_node(), equals(_node()));
      expect(_node().value, _node().value);
    });

    test('renders 64 lower-case hex characters', () {
      final value = _node().value;
      expect(value, hasLength(64));
      expect(value, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    // The reason the fields are length-prefixed rather than concatenated. Two
    // different hosts whose fields merely *join* to the same string must not
    // collapse onto one identity — that would be two machines sharing a UID.
    test('field boundaries are unambiguous (TLV framing)', () {
      expect(
        _node(machineId: 'ab', os: 'c'),
        isNot(equals(_node(machineId: 'a', os: 'bc'))),
      );
      expect(
        _node(hostname: 'edge', arch: '01'),
        isNot(equals(_node(hostname: 'edg', arch: 'e01'))),
      );
    });

    test('a node and a hub built from identical bytes do not collide', () {
      // Same key material, same machine, same platform: only the domain tag
      // differs, and that has to be enough.
      final key = Uint8List.fromList([1, 2, 3, 4]);
      expect(_node(publicKey: key), isNot(equals(_hub(keyMaterial: key))));
    });

    test('every field is part of the identity', () {
      final baseline = _node();
      expect(_node(machineId: 'machine-bbbb'), isNot(equals(baseline)));
      expect(_node(os: 'macos'), isNot(equals(baseline)));
      expect(_node(arch: 'arm64'), isNot(equals(baseline)));
      expect(_node(hostname: 'edge-02'), isNot(equals(baseline)));
      expect(
        _node(publicKey: Uint8List.fromList([9])),
        isNot(equals(baseline)),
      );
    });

    test('a keyless node hashes as an empty key, not as a missing field', () {
      // Token nodes pass no key at all; that must be a stable identity rather
      // than an error, and the same one an explicitly empty key produces.
      expect(_node(publicKey: null), equals(_node(publicKey: Uint8List(0))));
      // But it is still distinct from a node that does present a key.
      expect(
        _node(publicKey: null),
        isNot(equals(_node(publicKey: Uint8List.fromList([0])))),
      );
    });

    test('the hub scheme keeps the same properties', () {
      expect(_hub(), equals(_hub()));
      expect(_hub().value, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(_hub(machineId: 'machine-bbbb'), isNot(equals(_hub())));
      expect(_hub(keyMaterial: Uint8List.fromList([7])), isNot(equals(_hub())));
    });

    // A node's UID is its name on the fleet: if the scheme changes, every node
    // already registered becomes a stranger. These vectors pin `v1` — a
    // deliberate change means a new tag and a new expectation here, not an
    // edit to these strings.
    group('the v1 scheme is pinned', () {
      test('node', () {
        expect(
          UidComputer.computeNodeUid(
            publicKey: Uint8List.fromList(utf8.encode('public-key')),
            machineId: 'machine-aaaa',
            os: 'linux',
            arch: 'x64',
            hostname: 'edge-01',
          ).value,
          '9967d74d2279928fef806608a1322a7e00d3fffa635bff26870af23f7463a326',
        );
      });

      test('hub', () {
        expect(
          UidComputer.computeHubUid(
            keyMaterial: Uint8List.fromList(utf8.encode('tls-key')),
            machineId: 'machine-aaaa',
            os: 'linux',
            arch: 'x64',
            hostname: 'hub-01',
          ).value,
          '2c16be7ab10fcf2ebc5dc730c012b67afa9b1c98799a72ed857570dd40025017',
        );
      });
    });
  });
}
