@TestOn('vm')
@Tags(['docker'])
@Timeout(Duration(minutes: 10))
library;

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:test/test.dart';

import 'fleet.dart';

/// What the Hub refuses, across a real network and a real TLS handshake.
///
/// In-process tests hand the agent a `SecurityContext` and trust it. Here the
/// certificate is verified against a CA the node holds on disk, for a hostname
/// it resolves over Docker's DNS — so "the node trusts the Hub" is a claim
/// about a handshake rather than about an object.
void main() {
  late OmnyFleet fleet;

  setUp(() async {
    if (await OmnyFleet.unavailableReason() != null) return;
    fleet = await OmnyFleet.start();
  });

  tearDown(() async {
    if (await OmnyFleet.unavailableReason() != null) return;
    await fleet.dispose();
  });

  test('a node that does not hold the CA never registers', () async {
    if (await skipWithoutDocker()) return;
    await fleet.startHub();

    // No --ca and no --insecure: the dev CA is not in the system store, so the
    // handshake fails and the node has nothing to fall back on.
    final node = await fleet.startNode(
      id: 'untrusting-01',
      trustCa: false,
      waitForRegistration: false,
    );

    await Future<void>.delayed(const Duration(seconds: 5));

    final client = fleet.apiClient();
    try {
      expect(
        await client.get('/nodes'),
        isEmpty,
        reason: 'an unverified Hub is not a Hub to register with',
      );
    } finally {
      client.close();
    }
    // And it said why, rather than failing mutely.
    expect(
      '${node.stdout?.asString}${node.stderr?.asString}'.toLowerCase(),
      anyOf(contains('certificate'), contains('handshake'), contains('tls')),
    );
  });

  test('a node with the wrong token is refused, and says so', () async {
    if (await skipWithoutDocker()) return;
    await fleet.startHub();

    final node = await fleet.startNode(
      id: 'impostor-01',
      token: 'not-the-node-token',
      waitForRegistration: false,
    );

    await Future<void>.delayed(const Duration(seconds: 5));

    final client = fleet.apiClient();
    try {
      expect(await client.get('/nodes'), isEmpty);
    } finally {
      client.close();
    }
    expect(
      '${node.stdout?.asString}${node.stderr?.asString}'.toLowerCase(),
      anyOf(contains('auth'), contains('refused'), contains('rejected')),
    );
  });

  test('the API refuses a caller with no credential, and a bad one', () async {
    if (await skipWithoutDocker()) return;
    await fleet.startHub();

    final anonymous = fleet.apiClient(token: '');
    final wrong = fleet.apiClient(token: 'not-the-api-token');
    try {
      // Reached over TLS from outside the network: the transport is fine, the
      // caller is not.
      await expectLater(
        anonymous.get('/nodes'),
        throwsA(
          isA<HubApiException>().having(
            (e) => e.statusCode,
            'status',
            anyOf(401, 403),
          ),
        ),
      );
      await expectLater(
        wrong.get('/nodes'),
        throwsA(
          isA<HubApiException>().having(
            (e) => e.statusCode,
            'status',
            anyOf(401, 403),
          ),
        ),
      );
    } finally {
      anonymous.close();
      wrong.close();
    }
  });

  test("a node's credential cannot drive the API", () async {
    if (await skipWithoutDocker()) return;
    // The node fleet authenticates, but a node is not an operator: a machine
    // that is compromised should not be able to inspect or command the rest.
    await fleet.startHub();
    await fleet.startNode(id: 'worker-a');

    final asNode = fleet.apiClient(
      principal: 'node-account',
      token: OmnyFleet.nodeToken,
    );
    try {
      await expectLater(
        asNode.get('/nodes'),
        throwsA(
          isA<HubApiException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
    } finally {
      asNode.close();
    }
  });

  test('a grant issued at runtime works from another container', () async {
    if (await skipWithoutDocker()) return;
    await fleet.startHub();

    final admin = fleet.apiClient();
    try {
      final grant =
          await admin.post('/grants', {
                'principal': 'bob',
                'roles': ['viewer'],
                'note': 'issued in a container test',
              })
              as Map;
      final token = grant['token'] as String;

      // The token is shown once, and it works — over TLS, from outside.
      final asBob = fleet.apiClient(principal: 'bob', token: token);
      try {
        expect(await asBob.get('/nodes'), isEmpty);
      } finally {
        asBob.close();
      }

      // Revoked, it stops working.
      await admin.delete('/grants/${grant['id']}');
      final revoked = fleet.apiClient(principal: 'bob', token: token);
      try {
        await expectLater(
          revoked.get('/nodes'),
          throwsA(isA<HubApiException>()),
        );
      } finally {
        revoked.close();
      }
    } finally {
      admin.close();
    }
  });
}
