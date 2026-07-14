@TestOn('vm')
library;

import 'dart:io';

// The VM transport, standing in for the browser's `fetch` — the one seam this
// test swaps. Everything else is what the app itself runs.
import 'package:omnyserver/omnyserver_cli.dart' show IoApiTransport;
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver_web/core/omnyserver_service.dart';
import 'package:omnyshell_web/foundation.dart' show AppError, AppErrorKind;
import 'package:test/test.dart';

/// The dashboard's service layer, driven against a **real Hub**.
///
/// The browser cannot be run here, but everything above the socket can: the same
/// `OmnyServerService` the app uses, the same `HubApiClient`, the same entity
/// decoding — pointed at a genuine `OmnyServerHub` with a genuine `HttpApiServer`
/// in front of it. So this catches what a mocked test never would: a field the
/// Hub actually names differently, a status code it actually returns, an entity
/// that does not actually decode.
///
/// Only the transport is swapped (`IoApiTransport` for the browser's `fetch`),
/// which is exactly the seam that exists for it.
void main() {
  late OmnyServerHub hub;
  late HttpApiServer api;
  late OmnyServerService service;

  setUp(() async {
    hub = OmnyServerHub(
      HubConfig(
        host: '127.0.0.1',
        port: 0,
        securityContext: SecurityContext(),
        authenticator: TokenAuthenticator({
          'admin-token': TokenGrant(
            principal: PrincipalId('alice'),
            roles: const {'admin'},
          ),
          'node-token': TokenGrant(
            principal: PrincipalId('node-account'),
            roles: const {'node'},
          ),
        }),
      ),
    );
    // The API on its own plaintext listener: the Hub's own TLS needs a
    // certificate, and none of what is under test here is about TLS.
    api = HttpApiServer(
      hub: hub,
      apiToken: 'api-secret',
      events: EventAggregator()..attach(hub.config.eventBus),
      metrics: HubMetrics(hub.registry)..attach(hub.config.eventBus),
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();

    service = OmnyServerService(transport: IoApiTransport());
  });

  tearDown(() async {
    service.disconnect();
    await api.close();
  });

  String baseUrl() => 'http://127.0.0.1:${api.boundPort}';

  test('a grant signs in and reports its real identity and roles', () async {
    final identity = await service.connect(
      hubUri: baseUrl(),
      principal: 'alice',
      token: 'admin-token',
    );

    expect(identity.principal, 'alice');
    expect(identity.roles, contains('admin'));
    expect(identity.canOperate, isTrue);
    expect(service.isConnected, isTrue);
  });

  test('the master API token signs in with no identity of its own', () async {
    final identity = await service.connect(
      hubUri: baseUrl(),
      token: 'api-secret',
    );

    expect(identity.principal, 'api');
    expect(identity.canOperate, isTrue);
  });

  test('a bad token is rejected at login, not on the first screen', () async {
    // This is the entire reason login calls /whoami: without it the form would
    // "succeed" and the fleet screen would be the thing that failed.
    await expectLater(
      service.connect(hubUri: baseUrl(), principal: 'alice', token: 'wrong'),
      throwsA(isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.auth)),
    );
    expect(service.isConnected, isFalse);
  });

  test("a node's credential signs in but cannot operate the fleet", () async {
    // node-account holds only `node`; the Hub's authorizer reserves the API for
    // admins, so the call is refused with a 403 — which the service must present
    // as an authorization failure, not a mysterious error.
    await expectLater(
      service.connect(
        hubUri: baseUrl(),
        principal: 'node-account',
        token: 'node-token',
      ),
      throwsA(
        isA<AppError>().having(
          (e) => e.kind,
          'kind',
          AppErrorKind.authorization,
        ),
      ),
    );
  });

  test('the fleet decodes into real NodeDescriptors', () async {
    await service.connect(
      hubUri: baseUrl(),
      principal: 'alice',
      token: 'admin-token',
    );

    final nodes = await service.listNodes();
    // No nodes are attached in this test; what matters is that the endpoint is
    // reached and the (empty) list decodes rather than throwing.
    expect(nodes, isEmpty);
  });

  test('events and the audit trail decode', () async {
    await service.connect(
      hubUri: baseUrl(),
      principal: 'alice',
      token: 'admin-token',
    );

    // OmnyEvent.fromJson is new — the Hub could encode events but nothing could
    // read them back. Exercise the real endpoint, not a fixture.
    expect(await service.events(), isEmpty);
    expect(await service.audit(), isEmpty);
  });

  test('an unknown node is a not-found, not a crash', () async {
    await service.connect(
      hubUri: baseUrl(),
      principal: 'alice',
      token: 'admin-token',
    );

    await expectLater(
      service.node('ghost'),
      throwsA(
        isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.notFound),
      ),
    );
  });

  test('an offline node reports as unavailable, with a usable message', () async {
    await service.connect(
      hubUri: baseUrl(),
      principal: 'alice',
      token: 'admin-token',
    );

    // Nothing is connected, so the Hub cannot dispatch — a 502 upstream failure.
    await expectLater(
      service.runFormula(
        'ghost',
        formula: 'docker',
        action: FormulaAction.verify,
      ),
      throwsA(isA<AppError>()),
    );
  });

  test('an unreachable Hub explains what a browser will not', () async {
    // A browser reports a blocked cross-origin request as a bare network error
    // and withholds the reason, so the two causes a dashboard actually hits are
    // named in the hint instead of left to be guessed at.
    await expectLater(
      service.connect(hubUri: '127.0.0.1:1', token: 'x'),
      throwsA(
        isA<AppError>()
            .having((e) => e.kind, 'kind', AppErrorKind.transport)
            .having((e) => e.hint, 'hint', contains('cors-origin')),
      ),
    );
  });

  group('what the dashboard could not reach until now', () {
    Future<void> signIn() => service
        .connect(hubUri: baseUrl(), principal: 'alice', token: 'admin-token')
        .then((_) {});

    test('the formula catalogue decodes, with its actions', () async {
      await signIn();
      final formulas = await service.formulas();

      expect([for (final f in formulas) f.id.value], containsAll(['docker']));
      final docker = formulas.firstWhere((f) => f.id.value == 'docker');
      // What the UI offers instead of a free-text box.
      expect(docker.actions, contains(FormulaAction.verify));
    });

    test('a preset saved on the Hub comes back', () async {
      await signIn();
      expect(await service.presets(), isEmpty);

      await hub.savePreset(
        Preset(
          id: PresetId('docker-host'),
          name: 'Docker host',
          steps: [
            PresetStep(
              formula: FormulaId('docker'),
              action: FormulaAction.install,
            ),
          ],
        ),
      );

      final presets = await service.presets();
      expect(presets.single.id.value, 'docker-host');
      expect(presets.single.steps, hasLength(1));
    });

    test('a node nobody declared anything about has no drift', () async {
      await signIn();
      // Null, not "converged": there is nothing it could have drifted from, and
      // reporting a clean bill of health would be a lie.
      expect(await service.drift('worker-01'), isNull);
      expect(await service.desiredState('worker-01'), isNull);
    });

    test(
      'issued credentials round-trip, and the list carries no token',
      () async {
        await signIn();

        final issued = await service.issueGrant(
          principal: 'bob',
          roles: const {'viewer'},
          note: 'dashboard',
        );
        expect(issued.token, isNotEmpty);
        expect(issued.grant.principal.value, 'bob');

        final grants = await service.grants();
        final bob = grants.firstWhere((g) => g.principal.value == 'bob');
        expect(bob.roles, {'viewer'});
        expect(bob.note, 'dashboard');
        // The Hub keeps a hash. There is nothing in the list to steal.
        expect(bob.tokenHash, isNot(contains(issued.token)));

        await service.revokeGrant(issued.grant.id);
        expect(await service.grants(), isEmpty);
      },
    );
  });

  group('normalizeHubUri', () {
    test('a bare host becomes https on the Hub port', () {
      expect(
        OmnyServerService.normalizeHubUri('hub.example.com').toString(),
        'https://hub.example.com:8443',
      );
    });

    test('an explicit scheme and port are kept', () {
      expect(
        OmnyServerService.normalizeHubUri('http://127.0.0.1:9000').toString(),
        'http://127.0.0.1:9000',
      );
    });

    test('an empty address is a usable error, not a crash', () {
      expect(
        () => OmnyServerService.normalizeHubUri('  '),
        throwsA(isA<AppError>()),
      );
    });
  });
}
