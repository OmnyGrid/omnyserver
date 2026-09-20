@TestOn('vm')
library;

import 'dart:io';

// The VM transport, standing in for the browser's `fetch` — the one seam this
// test swaps. Everything else is what the app itself runs.
import 'package:omnyserver/omnyserver_cli.dart' show IoApiTransport;
// The browser's own blueprint parser, which the editor calls before saving.
import 'package:omnyserver/omnyserver_client_web.dart' show parseBlueprint;
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
          // Can sign in and read the fleet, and nothing else — the role the
          // library screen has to hide its editor from.
          'viewer-token': TokenGrant(
            principal: PrincipalId('vera'),
            roles: const {'viewer'},
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

    test('asking an unreachable node for its software is an AppError', () async {
      // The Software card's own failure mode. Nothing is connected here, so the
      // Hub cannot dispatch — and the panel has to get something it can show in
      // a banner rather than an exception it drops on the floor.
      await signIn();
      await expectLater(
        service.formulaStatus('ghost'),
        throwsA(isA<AppError>()),
      );
    });

    test('a blueprint saved on the Hub decodes, includes and all', () async {
      // The dashboard renders what it decodes here. A field the Hub names
      // differently, or a nested list that does not survive the trip, shows up
      // as an empty panel rather than as an error — so it is worth asserting
      // against a real Hub rather than a fixture.
      await signIn();
      expect(await service.blueprints(), isEmpty);

      await hub.savePreset(
        Preset(
          id: PresetId('dev-tools'),
          name: 'Dev tools',
          steps: [PresetStep(formula: FormulaId('dart'))],
        ),
      );
      await hub.saveBlueprint(
        Blueprint(
          id: BlueprintId('builder'),
          name: 'Build host',
          includes: [PresetId('dev-tools')],
          resources: [
            Resource(
              id: ResourceId('formula', 'nmap'),
              ensure: Ensure.installed,
            ),
          ],
        ),
      );

      final blueprints = await service.blueprints();
      expect(blueprints.single.id.value, 'builder');
      expect(blueprints.single.includes.single.value, 'dev-tools');
      expect(blueprints.single.resources.single.ensure, Ensure.installed);
    });

    test('assigning to a node nobody has registered is a usable error', () async {
      // What the panel shows in a banner. An exception dropped on the floor
      // would leave the operator looking at a control that silently did nothing.
      await signIn();
      await hub.saveBlueprint(Blueprint(id: BlueprintId('bare'), name: 'Bare'));

      await expectLater(
        service.assignBlueprint('ghost', 'bare'),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.notFound),
        ),
      );
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

  /// The library screen's whole surface. Every one of these methods existed on
  /// `HubApiClient` and was unreachable from the dashboard until the Library
  /// screen needed it, so none of them had ever been driven end to end.
  group('the library screen', () {
    Future<void> signIn() => service
        .connect(hubUri: baseUrl(), principal: 'alice', token: 'admin-token')
        .then((_) {});

    const yaml =
        '# Everything a build host needs.\n'
        'blueprint: builder\n'
        'name: Build host\n'
        'includes: [dev-tools]\n'
        'resources:\n'
        '  - { type: formula, name: nmap, ensure: installed }\n';

    test('a blueprint authored in the browser round-trips verbatim', () async {
      // The editor's entire premise: what somebody typed comes back as what
      // they typed. A Hub that re-rendered the document from its parse would
      // lose the comment on the first line, and the file in the editor and the
      // thing on the Hub would be two documents that happen to agree.
      await signIn();
      await hub.savePreset(Preset(id: PresetId('dev-tools'), name: 'Dev'));

      await service.saveBlueprint(
        parseBlueprint(yaml, BlueprintFormat.yaml, origin: 'the editor'),
      );

      final saved = await service.blueprint('builder');
      expect(saved.name, 'Build host');
      expect(saved.source?.format, BlueprintFormat.yaml);
      expect(saved.source?.text, yaml);
      expect(saved.includes.single.value, 'dev-tools');
    });

    test('the resolved view names where each resource came from', () async {
      await signIn();
      await hub.savePreset(
        Preset(
          id: PresetId('dev-tools'),
          name: 'Dev',
          steps: [PresetStep(formula: FormulaId('dart'))],
        ),
      );
      await service.saveBlueprint(
        parseBlueprint(yaml, BlueprintFormat.yaml, origin: 'the editor'),
      );

      final resolved = await service.resolvedBlueprint('builder');

      // The include is flattened in and the blueprint's own resource follows
      // it, each carrying the provenance the screen renders.
      expect(resolved.hash, isNotEmpty);
      expect(
        [for (final r in resolved.resources) r.id.toString()],
        ['formula:dart', 'formula:nmap'],
      );
      expect(resolved.resources.first.origin, contains('dev-tools'));
      expect(resolved.resources.last.origin, 'local');
    });

    test('a blueprint the Hub cannot resolve is refused on save', () async {
      // The reason the editor does not validate includes itself: only the Hub
      // knows what is saved on it. The message has to arrive intact, because it
      // is the only thing the author is shown.
      await signIn();
      await expectLater(
        service.saveBlueprint(
          parseBlueprint(
            'blueprint: orphan\nincludes: [nobody-saved-this]\nresources: []\n',
            BlueprintFormat.yaml,
          ),
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.message,
            'message',
            contains('nobody-saved-this'),
          ),
        ),
      );
    });

    test('a preset round-trips through the editor, then deletes', () async {
      await signIn();
      await service.savePreset(
        Preset(
          id: PresetId('base-tools'),
          name: 'Base tools',
          description: 'What every machine gets',
          steps: [
            PresetStep(formula: FormulaId('git')),
            PresetStep(
              formula: FormulaId('docker'),
              action: FormulaAction.start,
            ),
          ],
        ),
      );

      final saved = await service.preset('base-tools');
      expect(saved.description, 'What every machine gets');
      expect(saved.steps.last.action, FormulaAction.start);

      await service.deletePreset('base-tools');
      expect(await service.presets(), isEmpty);
    });

    test('deleting a blueprint takes it out of the list', () async {
      await signIn();
      await hub.saveBlueprint(Blueprint(id: BlueprintId('bare'), name: 'Bare'));
      expect(await service.blueprints(), hasLength(1));

      await service.deleteBlueprint('bare');
      expect(await service.blueprints(), isEmpty);
    });

    test('reading a blueprint nobody saved is a notFound, not a crash', () {
      return signIn().then(
        (_) => expectLater(
          service.blueprint('ghost'),
          throwsA(
            isA<AppError>().having(
              (e) => e.kind,
              'kind',
              AppErrorKind.notFound,
            ),
          ),
        ),
      );
    });

    test('a viewer is refused the editor by the Hub, not just the UI', () async {
      // The screen hides Save from a viewer, but hiding a button is a courtesy
      // and not a control. This is the one that matters: a viewer who reaches
      // the endpoint anyway is refused, and the service reports it as an
      // authorization failure so the toast says so.
      await service.connect(
        hubUri: baseUrl(),
        principal: 'vera',
        token: 'viewer-token',
      );

      await expectLater(
        service.saveBlueprint(
          parseBlueprint(
            'blueprint: sneaky\nresources: []\n',
            BlueprintFormat.yaml,
          ),
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.authorization,
          ),
        ),
      );
      // Reading is a viewer's whole job, and must still work.
      expect(await service.blueprints(), isEmpty);
    });

    test('an unusable label selector is reported, not silently ignored', () {
      // The assign panel sends whatever was typed. A selector the Hub cannot
      // parse must come back as an error the panel can show — assigning to the
      // *whole fleet* because a selector was dropped is the failure worth
      // preventing.
      return signIn().then(
        (_) => expectLater(
          service.listNodes(labels: const ['role']),
          throwsA(isA<AppError>()),
        ),
      );
    });
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
