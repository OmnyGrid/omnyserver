@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

void main() {
  final challenge = Uint8List.fromList(utf8.encode('nonce-123'));

  group('TokenAuthenticator', () {
    late TokenAuthenticator auth;
    setUp(() {
      auth = TokenAuthenticator({
        'admin-token': TokenGrant(
          principal: PrincipalId('alice'),
          roles: const {'admin'},
        ),
      });
    });

    test('valid token resolves the principal and roles', () async {
      final p = await auth.authenticate(
        const Credential.token(principal: 'alice', token: 'admin-token'),
        challenge: challenge,
      );
      expect(p.id.value, 'alice');
      expect(p.hasRole('admin'), isTrue);
    });

    test('wrong token is rejected', () {
      expect(
        () => auth.authenticate(
          const Credential.token(principal: 'alice', token: 'nope'),
          challenge: challenge,
        ),
        throwsA(isA<AuthException>()),
      );
    });

    test('token/principal mismatch is rejected', () {
      expect(
        () => auth.authenticate(
          const Credential.token(principal: 'mallory', token: 'admin-token'),
          challenge: challenge,
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('PublicKeyAuthenticator', () {
    test('a valid signature over the challenge authenticates', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final pub = await keyPair.extractPublicKey();
      final key = Ed25519PublicKey.fromBytes(pub.bytes);

      final store = AuthorizedKeysStore([
        AuthorizedKey(principal: 'node-a', key: key, roles: const {'node'}),
      ]);
      final auth = PublicKeyAuthenticator(store);

      final sig = await algorithm.sign(challenge, keyPair: keyPair);
      final cred = Credential(
        principal: 'node-a',
        publicKey: key.base64,
        signature: base64.encode(sig.bytes),
      );

      final p = await auth.authenticate(cred, challenge: challenge);
      expect(p.id.value, 'node-a');
      expect(p.hasRole('node'), isTrue);
    });

    test('a signature over a different challenge fails', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final pub = await keyPair.extractPublicKey();
      final key = Ed25519PublicKey.fromBytes(pub.bytes);
      final auth = PublicKeyAuthenticator(
        AuthorizedKeysStore([AuthorizedKey(principal: 'node-a', key: key)]),
      );
      final sig = await algorithm.sign(
        Uint8List.fromList(utf8.encode('other')),
        keyPair: keyPair,
      );
      final cred = Credential(
        principal: 'node-a',
        publicKey: key.base64,
        signature: base64.encode(sig.bytes),
      );
      expect(
        () => auth.authenticate(cred, challenge: challenge),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('RoleBasedAuthorizer', () {
    test('admin may do anything; others fail closed', () {
      const authz = RoleBasedAuthorizer();
      final admin = Principal(id: PrincipalId('a'), roles: const {'admin'});
      final node = Principal(id: PrincipalId('n'), roles: const {'node'});
      expect(authz.authorize(admin, 'node.restart'), isTrue);
      expect(authz.authorize(node, 'node.restart'), isFalse);
    });

    test('mapped action roles are honored', () {
      const authz = RoleBasedAuthorizer(
        actionRoles: {
          'node.': {'operator'},
        },
      );
      final op = Principal(id: PrincipalId('o'), roles: const {'operator'});
      expect(authz.authorize(op, 'node.restart'), isTrue);
      expect(authz.authorize(op, 'preset.apply'), isFalse);
    });
  });
}
