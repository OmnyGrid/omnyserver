@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// The Hub can take its certificate from a LetsEncrypt-style directory
/// (`fullchain.pem` + `privkey.pem`) instead of an explicit `--cert`/`--key`
/// pair, and reload it when it is renewed. This pins the two halves of that: the
/// directory really drives the TLS listener (a node completes a `wss` handshake
/// against it), and the CLI accepts exactly one TLS source — never both, never
/// neither, since the Hub has no insecure mode.
/// [pem] with CRLF line endings normalised to LF, so a PEM read from disk and
/// one handed back by Dart's TLS stack compare equal on every platform.
String _lf(String pem) => pem.replaceAll('\r\n', '\n').trim();

void main() {
  late Directory tlsDir;

  setUp(() async {
    final certs = await TestCerts.ensure();
    tlsDir = Directory.systemTemp.createTempSync('omnyserver-tls-dir');
    File(certs.serverCert).copySync('${tlsDir.path}/fullchain.pem');
    File(certs.serverKey).copySync('${tlsDir.path}/privkey.pem');
  });

  tearDown(() {
    if (tlsDir.existsSync()) tlsDir.deleteSync(recursive: true);
  });

  test('a Hub configured with tlsDirectory serves it, and nodes over wss', () async {
    final hub = OmnyServerHub(
      HubConfig(
        host: '127.0.0.1',
        port: 0,
        tlsDirectory: tlsDir.path,
        authenticator: TokenAuthenticator({
          'node-token': TokenGrant(
            principal: PrincipalId('node-account'),
            roles: const {'node'},
          ),
        }),
        heartbeatInterval: const Duration(milliseconds: 200),
      ),
    );
    await hub.start();

    // The listener really presents the directory's certificate — not merely some
    // certificate. Verification itself is the peer's business (and the dev CA's
    // leaf is only trusted on some platforms), so the socket accepts the cert and
    // then compares what was served against the leaf in fullchain.pem.
    final socket = await SecureSocket.connect(
      '127.0.0.1',
      hub.port,
      onBadCertificate: (_) => true,
    );
    final served = socket.peerCertificate!.pem;
    socket.destroy();
    // Compared with line endings normalised: openssl writes the PEM with CRLF on
    // Windows, while Dart hands back the certificate with LF.
    expect(
      _lf(File('${tlsDir.path}/fullchain.pem').readAsStringSync()),
      contains(_lf(served)),
    );

    final agent = NodeAgent(
      NodeAgentConfig(
        hubUri: Uri.parse('wss://127.0.0.1:${hub.port}'),
        nodeId: 'worker-01',
        credentials: TokenCredentialProvider(
          principal: 'node-account',
          token: 'node-token',
        ),
        securityContext: await TestCerts.trustContext(),
        onBadCertificate: (cert, host, port) => true,
      ),
    );
    await agent.start();

    expect(hub.getNode(NodeId('worker-01')), isNotNull);

    await agent.stop();
    await hub.close();
  });

  test('HubConfig demands exactly one TLS source', () async {
    expect(
      () => HubConfig(authenticator: TokenAuthenticator(const {})),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () async => HubConfig(
        securityContext: await TestCerts.serverContext(),
        tlsDirectory: tlsDir.path,
        authenticator: TokenAuthenticator(const {}),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  group('hub start TLS options', () {
    test('rejects --tls-dir together with --cert/--key', () async {
      final certs = await TestCerts.ensure();
      expect(
        () => buildRunner().run([
          'hub',
          'start',
          '--tls-dir',
          tlsDir.path,
          '--cert',
          certs.serverCert,
          '--key',
          certs.serverKey,
        ]),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('not both'),
          ),
        ),
      );
    });

    test('rejects a --tls-dir without fullchain.pem/privkey.pem', () {
      final empty = Directory.systemTemp.createTempSync('omnyserver-tls-empty');
      addTearDown(() => empty.deleteSync(recursive: true));
      expect(
        () => buildRunner().run(['hub', 'start', '--tls-dir', empty.path]),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('must contain fullchain.pem and privkey.pem'),
          ),
        ),
      );
    });

    test('rejects neither --tls-dir nor --cert/--key', () {
      expect(
        () => buildRunner().run(['hub', 'start']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('--cert and --key are required unless --tls-dir is set'),
          ),
        ),
      );
    });
  });
}
