@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart' show CliError;
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

/// The value objects are identifiers, and identifiers are used as map keys, in
/// sets and in log lines. Equality, `hashCode` and `toString` are the whole
/// contract; a mismatched pair silently duplicates a node in a set.
void main() {
  group('identifiers are values, not references', () {
    test('NodeId', () {
      expect(NodeId('a'), NodeId('a'));
      expect({NodeId('a'), NodeId('a')}, hasLength(1));
      expect(NodeId('a').hashCode, NodeId('a').hashCode);
      expect('${NodeId('a')}', 'a');
    });

    test('PrincipalId', () {
      expect(PrincipalId('alice'), PrincipalId('alice'));
      expect({PrincipalId('alice'), PrincipalId('alice')}, hasLength(1));
      expect('${PrincipalId('alice')}', 'alice');
    });

    test('FormulaId', () {
      expect(FormulaId('docker'), FormulaId('docker'));
      expect({FormulaId('docker'), FormulaId('docker')}, hasLength(1));
      expect('${FormulaId('docker')}', 'docker');
    });

    test('PresetId', () {
      expect(PresetId('web'), PresetId('web'));
      expect({PresetId('web'), PresetId('web')}, hasLength(1));
      expect('${PresetId('web')}', 'web');
    });

    test('OmnyUid, which is a hex digest and normalises its case', () {
      final uid = OmnyUid('DEADBEEF');
      expect(uid, OmnyUid('deadbeef'));
      expect({uid, OmnyUid('deadbeef')}, hasLength(1));
      expect('$uid', 'deadbeef');

      // It is content-derived, not operator-chosen: a label is not a uid.
      expect(() => OmnyUid('web-01'), throwsA(isA<ProtocolException>()));
      expect(() => OmnyUid('  '), throwsA(isA<ProtocolException>()));
    });
  });

  group('Ed25519PublicKey', () {
    /// 32 bytes, so it is a well-formed key.
    final bytes = List<int>.generate(32, (i) => i);

    test('is equal by key bytes, and prints its base64', () {
      final a = Ed25519PublicKey.fromBytes(bytes);
      final b = Ed25519PublicKey.fromBase64(a.base64);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));
      expect('$a', contains(a.base64));
    });

    test('a url-safe encoding is accepted and canonicalised', () {
      final a = Ed25519PublicKey.fromBytes(List.filled(32, 0xFB));
      final urlSafe = a.base64.replaceAll('+', '-').replaceAll('/', '_');
      expect(Ed25519PublicKey.fromBase64(urlSafe), a);
    });

    test('a key that is not base64 says so, and shows what it got', () {
      expect(
        () => Ed25519PublicKey.fromBase64('not base64 at all!!'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('Invalid base64 public key'),
          ),
        ),
      );
    });

    test('a key of the wrong length is refused with its length', () {
      expect(
        () => Ed25519PublicKey.fromBytes(const [1, 2, 3]),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('got 3'),
          ),
        ),
      );
    });
  });

  group('Capability', () {
    test('is equal by kind, name and version', () {
      const a = Capability(
        kind: CapabilityKind.docker,
        name: 'docker',
        version: '27',
      );
      const b = Capability(
        kind: CapabilityKind.docker,
        name: 'docker',
        version: '27',
      );
      const other = Capability(
        kind: CapabilityKind.docker,
        name: 'docker',
        version: '26',
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      // Built by adding rather than as a literal: with two constants the
      // analyzer proves the duplicate and flags the literal, which is precisely
      // the property under test.
      final unique = <Capability>{}
        ..add(a)
        ..add(b);
      expect(unique, hasLength(1));
      expect(a, isNot(other));
      // Details are descriptive, not identifying: the same tool at the same
      // version is the same capability whatever the detector noticed about it.
      expect(
        a,
        const Capability(
          kind: CapabilityKind.docker,
          name: 'docker',
          version: '27',
          details: {'rootless': 'true'},
        ),
      );
    });

    test('prints its name, with the version when it has one', () {
      expect(
        '${const Capability(kind: CapabilityKind.git, name: 'git', version: '2.4')}',
        contains('git@2.4'),
      );
      expect(
        '${const Capability(kind: CapabilityKind.git, name: 'git')}',
        isNot(contains('@')),
      );
    });

    test('an unknown wire name parses as custom, not as an error', () {
      expect(CapabilityKind.parse('docker'), CapabilityKind.docker);
      expect(CapabilityKind.parse('quantum-annealer'), CapabilityKind.custom);
    });
  });

  group('ValidationResult', () {
    test('round-trips through JSON', () {
      final ok = ValidationResult.ok(version: '1.2', message: 'found');
      final decoded = ValidationResult.fromJson(ok.toJson());
      expect(decoded.valid, isTrue);
      expect(decoded.detectedVersion, '1.2');
      expect(decoded.message, 'found');
    });

    test('a failure carries no version and keeps its reason', () {
      final failed = ValidationResult.fail('not installed');
      final json = failed.toJson();
      expect(json.containsKey('detectedVersion'), isFalse);

      final decoded = ValidationResult.fromJson(json);
      expect(decoded.valid, isFalse);
      expect(decoded.message, 'not installed');
    });

    test('an empty object decodes to an invalid, unexplained result', () {
      final decoded = ValidationResult.fromJson(const {});
      expect(decoded.valid, isFalse);
      expect(decoded.message, isEmpty);
      expect(decoded.detectedVersion, isNull);
    });
  });

  group('FormulaSpec', () {
    test('an empty platform list means every platform', () {
      final anywhere = FormulaSpec(id: FormulaId('docker'), name: 'Docker');
      expect(anywhere.supportsPlatform('linux'), isTrue);
      expect(anywhere.supportsPlatform('windows'), isTrue);
      expect('$anywhere', contains('docker'));
    });

    test('a platform list is exclusive', () {
      final posixOnly = FormulaSpec(
        id: FormulaId('procps'),
        name: 'procps',
        supportedPlatforms: const ['linux', 'macos'],
      );
      expect(posixOnly.supportsPlatform('linux'), isTrue);
      expect(posixOnly.supportsPlatform('windows'), isFalse);
    });
  });

  group('ReconnectPolicy', () {
    test('backs off exponentially and then stops growing', () {
      const policy = ReconnectPolicy(
        initial: Duration(seconds: 1),
        max: Duration(seconds: 10),
        factor: 2,
      );

      expect(policy.delayFor(0), const Duration(seconds: 1));
      expect(policy.delayFor(1), const Duration(seconds: 2));
      expect(policy.delayFor(2), const Duration(seconds: 4));
      // Capped, and it stays capped however many attempts have failed — the
      // point of a ceiling is that a long outage does not become an hour-long
      // wait after it ends.
      expect(policy.delayFor(10), const Duration(seconds: 10));
      expect(policy.delayFor(100), const Duration(seconds: 10));
    });

    test('the default policy is the documented one', () {
      const policy = ReconnectPolicy();
      expect(policy.delayFor(0), const Duration(seconds: 1));
      expect(policy.delayFor(20), const Duration(seconds: 30));
    });
  });

  group('the classified failures', () {
    test('each carries its stable code and its message', () {
      const cases = <(OmnyServerException, String)>[
        (ProtocolException('p'), ErrorCodes.protocolError),
        (AuthException('a'), ErrorCodes.authFailed),
        (AuthorizationException('z'), ErrorCodes.notAuthorized),
        (NotFoundException('n'), ErrorCodes.notFound),
        (OperationException('o'), ErrorCodes.operationFailed),
        (StorageException('s'), ErrorCodes.storageError),
        (TransportException('t'), ErrorCodes.transportError),
        (OmnyServerTimeoutException('to'), ErrorCodes.timeout),
        (
          NodeUnavailableException(ErrorCodes.nodeOffline, 'off'),
          ErrorCodes.nodeOffline,
        ),
      ];

      for (final (exception, code) in cases) {
        expect(exception.code, code, reason: '$exception');
        expect(exception.message, isNotEmpty);
        // The string form names the type and the code, so a log line says what
        // went wrong without the catcher having to.
        expect('$exception', contains(code));
        expect('$exception', contains(exception.message));
      }
    });

    test('a code can be overridden where the wire says so', () {
      expect(
        const ProtocolException('v', code: ErrorCodes.versionMismatch).code,
        ErrorCodes.versionMismatch,
      );
      expect(
        const OperationException('x', code: ErrorCodes.timeout).code,
        ErrorCodes.timeout,
      );
    });
  });

  group('OmnyServerHome', () {
    test('an explicit override wins over the environment', () {
      expect(
        OmnyServerHome.resolve(override: '/tmp/somewhere'),
        '/tmp/somewhere',
      );
    });

    test('a blank override falls through to the resolved default', () {
      expect(OmnyServerHome.resolve(override: '   '), OmnyServerHome.resolve());
      expect(OmnyServerHome.resolve(), endsWith('.omnyserver'));
    });

    test('ensure creates the directory, and is idempotent', () {
      final tmp = Directory.systemTemp.createTempSync('omnyserver-home');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final target = '${tmp.path}/nested/home';

      expect(OmnyServerHome.ensure(override: target).existsSync(), isTrue);
      expect(OmnyServerHome.ensure(override: target).existsSync(), isTrue);
    });
  });

  group('CliError', () {
    test('prints as its message, with no exception noise around it', () {
      expect('${CliError('--cert is required')}', '--cert is required');
    });
  });

  group('Principal', () {
    test('holds only the roles it was granted, and says which', () {
      final principal = Principal(
        id: PrincipalId('alice'),
        roles: const {'admin', 'operator'},
      );
      expect(principal.hasRole('admin'), isTrue);
      expect(principal.hasRole('viewer'), isFalse);
      expect('$principal', contains('alice'));
      expect('$principal', contains('admin'));
    });

    test('a principal with no roles holds none', () {
      final principal = Principal(id: PrincipalId('nobody'));
      expect(principal.hasRole('admin'), isFalse);
      expect(principal.roles, isEmpty);
    });
  });
}
