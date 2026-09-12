@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

Uint8List _challenge(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (i + seed) & 0xff));

/// A fixed seed, so the key pair — and therefore the public key on the wire —
/// is the same on every run.
final List<int> _seed = List<int>.filled(32, 7);

void main() {
  group('TokenCredentialProvider', () {
    test('presents its token and ignores the challenge', () async {
      const provider = TokenCredentialProvider(
        principal: 'alice',
        token: 'admin-token',
      );
      final first = await provider.provide(challenge: _challenge(0));
      final second = await provider.provide(challenge: _challenge(99));

      expect(first.principal, 'alice');
      expect(first.token, 'admin-token');
      expect(first.publicKey, isNull);
      expect(first.signature, isNull);
      // A token is a token: a different challenge changes nothing about it.
      expect(second.token, first.token);
    });
  });

  group('PublicKeyCredentialProvider', () {
    late PublicKeyCredentialProvider provider;

    setUp(() async {
      provider = await PublicKeyCredentialProvider.fromSeed(
        principal: 'node-01',
        seed: _seed,
      );
    });

    test('signs the challenge it was given', () async {
      final challenge = _challenge(1);
      final credential = await provider.provide(challenge: challenge);

      expect(credential.principal, 'node-01');
      expect(credential.token, isNull);
      expect(credential.publicKey, isNotNull);
      expect(credential.signature, isNotNull);

      // The signature has to verify against the challenge under the public key
      // the credential itself carries — that pair is all the Hub gets.
      final verified = await Ed25519().verify(
        challenge,
        signature: Signature(
          base64.decode(credential.signature!),
          publicKey: SimplePublicKey(
            base64.decode(credential.publicKey!),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      expect(verified, isTrue);
    });

    test('a signature does not verify against another challenge', () async {
      // Why the provider signs the challenge at all: a credential captured off
      // one connection must be useless on the next, which issues its own.
      final credential = await provider.provide(challenge: _challenge(1));
      final replayed = await Ed25519().verify(
        _challenge(2),
        signature: Signature(
          base64.decode(credential.signature!),
          publicKey: SimplePublicKey(
            base64.decode(credential.publicKey!),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      expect(replayed, isFalse);
    });

    test('the same seed is the same identity across providers', () async {
      final other = await PublicKeyCredentialProvider.fromSeed(
        principal: 'node-01',
        seed: _seed,
      );
      final mine = await provider.provide(challenge: _challenge(3));
      final theirs = await other.provide(challenge: _challenge(3));
      expect(theirs.publicKey, mine.publicKey);
    });

    test('a different seed is a different identity', () async {
      final other = await PublicKeyCredentialProvider.fromSeed(
        principal: 'node-01',
        seed: List<int>.filled(32, 8),
      );
      final mine = await provider.provide(challenge: _challenge(3));
      final theirs = await other.provide(challenge: _challenge(3));
      expect(theirs.publicKey, isNot(mine.publicKey));
    });
  });
}
