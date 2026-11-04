@TestOn('vm')
library;

import 'package:dart_service_manager/dart_service_manager.dart' as dsm;
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

import '../support/fake_service_backend.dart';

void main() {
  late FakeBackend backend;
  late ScriptedProbe probe;
  final context = FormulaContext(
    platform: PlatformInfo.local(agentVersion: omnyServerVersion),
  );

  ServiceProvider provider({
    List<String>? roots,
    bool root = true,
    bool canSwitchUser = false,
  }) => ServiceProvider(
    backend: backend,
    probe: probe,
    allowedRoots: roots,
    runningAsRoot: root,
    canSwitchUser: canSwitchUser,
    lookupUser: (user) =>
        user == 'app' ? (uid: 1001, gid: 1002, home: '/home/app') : null,
    delay: (_) async {},
  );

  ResolvedResource service(
    Map<String, String> params, {
    Ensure ensure = Ensure.running,
    String name = 'api',
  }) => ResolvedResource(
    resource: Resource(
      id: ResourceId('service', name),
      ensure: ensure,
      params: {'exec': '/opt/app/current/bin/api', ...params},
    ),
    origin: 'local',
  );

  setUp(() {
    backend = FakeBackend();
    probe = ScriptedProbe([]);
  });

  Future<ResourceChange> apply(ServiceProvider sp, ResolvedResource r) async =>
      sp.apply(r, await sp.read(r, context), context);

  group('descriptor', () {
    test('turns the declaration into a unit', () {
      final d = provider().descriptorFor(
        service({
          'args': '--config "/etc/my app.yaml" -v',
          'working_dir': '/opt/app/current',
          'env_file': '/etc/app.env',
          'env.TZ': 'UTC',
          'env.': 'ignored',
          'restart': 'on-failure',
          'restart_delay': '9',
          'stop_timeout': '20',
          'description': 'The API',
        }),
      );
      expect(d.packageName, DsmServiceBackend.managedPackage);
      expect(d.serviceName, 'api');
      expect(d.executablePath, '/opt/app/current/bin/api');
      expect(d.arguments, ['--config', '/etc/my app.yaml', '-v']);
      expect(d.workingDirectory, '/opt/app/current');
      expect(d.environmentFile, '/etc/app.env');
      expect(d.environment, {'TZ': 'UTC'});
      expect(d.restart, dsm.RestartPolicy.onFailure);
      expect(d.restartDelay, const Duration(seconds: 9));
      expect(d.stopTimeout, const Duration(seconds: 20));
      expect(d.description, 'The API');
      expect(d.scope, dsm.ServiceScope.system);
    });

    test('installs per-user when the agent is not root, unless told', () {
      expect(
        provider(root: false).descriptorFor(service({})).scope,
        dsm.ServiceScope.user,
      );
      expect(
        provider(root: false).descriptorFor(service({'scope': 'system'})).scope,
        dsm.ServiceScope.system,
      );
      expect(
        () => provider().descriptorFor(service({'scope': 'galaxy'})),
        throwsArgumentError,
      );
    });

    test('refuses a missing or relative exec, and a bad restart policy', () {
      expect(
        () => provider().descriptorFor(
          ResolvedResource(
            resource: Resource(id: ResourceId('service', 'x')),
            origin: 'local',
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => provider().descriptorFor(service({'exec': 'bin/api'})),
        throwsArgumentError,
      );
      expect(
        () => provider().descriptorFor(service({'restart': 'sometimes'})),
        throwsArgumentError,
      );
    });

    test('an exec or working dir outside --allow-root is refused', () {
      final confined = provider(roots: ['/opt/app']);
      expect(confined.descriptorFor(service({})), isNotNull);
      expect(
        () => confined.descriptorFor(service({'exec': '/usr/bin/curl'})),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('outside what this node allows'),
          ),
        ),
      );
      expect(
        () => confined.descriptorFor(service({'working_dir': '/tmp'})),
        throwsArgumentError,
      );
      // A sibling that merely shares the prefix is not inside.
      expect(
        () => confined.descriptorFor(service({'exec': '/opt/app-evil/x'})),
        throwsArgumentError,
      );
    });

    test('user: runs through setpriv, with HOME and USER to match', () {
      final d = provider(
        canSwitchUser: true,
      ).descriptorFor(service({'user': 'app', 'args': '-p 8080'}));
      expect(d.executablePath, '/usr/bin/setpriv');
      expect(d.arguments, [
        '--reuid=1001',
        '--regid=1002',
        '--init-groups',
        '--',
        '/opt/app/current/bin/api',
        '-p',
        '8080',
      ]);
      expect(d.environment, {
        'HOME': '/home/app',
        'USER': 'app',
        'LOGNAME': 'app',
      });
    });

    test('user: is refused where it cannot be honoured, never ignored', () {
      expect(
        () => provider().descriptorFor(service({'user': 'app'})),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('refuses'),
          ),
        ),
      );
      expect(
        () => provider(
          canSwitchUser: true,
        ).descriptorFor(service({'user': 'nobody-here'})),
        throwsArgumentError,
      );
    });
  });

  group('splitArguments', () {
    test('splits like a shell, and only like a shell', () {
      expect(ServiceProvider.splitArguments(''), isEmpty);
      expect(ServiceProvider.splitArguments('  a   b  '), ['a', 'b']);
      expect(ServiceProvider.splitArguments('a "b c" d'), ['a', 'b c', 'd']);
      expect(ServiceProvider.splitArguments("'\$HOME' x"), [r'$HOME', 'x']);
      expect(ServiceProvider.splitArguments(r'a\ b'), ['a b']);
      expect(ServiceProvider.splitArguments(r'"say \"hi\""'), ['say "hi"']);
      expect(ServiceProvider.splitArguments('""'), ['']);
      expect(
        () => ServiceProvider.splitArguments('"open'),
        throwsArgumentError,
      );
    });
  });

  group('read and satisfies', () {
    test('nothing installed is absent', () async {
      final sp = provider();
      final state = await sp.read(service({}), context);
      expect(state.status, FormulaStatus.absent);
      expect(sp.satisfies(service({}), state), isFalse);
      expect(sp.satisfies(service({}, ensure: Ensure.absent), state), isTrue);
    });

    test('maps the service manager status', () async {
      final sp = provider();
      final r = service({});
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(r),
        status: dsm.ServiceStatus.failed,
      );
      expect((await sp.read(r, context)).status, FormulaStatus.failed);
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(r),
        status: dsm.ServiceStatus.unknown,
      );
      expect((await sp.read(r, context)).status, FormulaStatus.unknown);
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(r),
        status: dsm.ServiceStatus.paused,
      );
      expect((await sp.read(r, context)).status, FormulaStatus.stopped);
    });

    test('a running unit matching the declaration converges', () async {
      final sp = provider();
      final r = service({'args': '-v'});
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(r),
        status: dsm.ServiceStatus.running,
      );
      final state = await sp.read(r, context);
      expect(sp.satisfies(r, state), isTrue);
      expect(
        sp.satisfies(service({'args': '-v'}, ensure: Ensure.stopped), state),
        isFalse,
      );
    });

    test('a unit that differs from the declaration has drifted', () async {
      final sp = provider();
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(service({'args': '-v'})),
        status: dsm.ServiceStatus.running,
      );
      final changed = service({'args': '-vv'});
      expect(sp.satisfies(changed, await sp.read(changed, context)), isFalse);
    });

    test(
      'a declaration that cannot become a unit converges on nothing',
      () async {
        final sp = provider();
        backend.units['api'] = InstalledService.of(
          sp.descriptorFor(service({})),
          status: dsm.ServiceStatus.running,
        );
        final broken = service({'restart': 'sometimes'});
        expect(sp.satisfies(broken, await sp.read(broken, context)), isFalse);
      },
    );
  });

  group('apply', () {
    test('installs and starts a new service', () async {
      final change = await apply(provider(), service({}));
      expect(change.kind, ChangeKind.create, reason: change.reason);
      expect(change.reason, 'installed and running');
      expect(backend.calls, ['install api', 'start api']);
    });

    test('installs a service declared stopped without starting it', () async {
      final change = await apply(
        provider(),
        service({}, ensure: Ensure.stopped),
      );
      expect(change.kind, ChangeKind.create);
      expect(backend.calls, ['install api']);
    });

    test('reconfigures a drifted unit, which restarts it if running', () async {
      final sp = provider();
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(service({'args': '-v'})),
        status: dsm.ServiceStatus.running,
      );
      final change = await apply(sp, service({'args': '-vv'}));
      expect(change.kind, ChangeKind.update, reason: change.reason);
      expect(change.reason, 'reconfigured and running');
      expect(backend.calls, ['reconfigure api']);
    });

    test('reconfigures a stopped drifted unit and starts it', () async {
      final sp = provider();
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(service({'args': '-v'})),
        status: dsm.ServiceStatus.stopped,
      );
      await apply(sp, service({'args': '-vv'}));
      expect(backend.calls, ['reconfigure api', 'start api']);
    });

    test('reconfigures and stops a drifted unit declared stopped', () async {
      final sp = provider();
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(service({'args': '-v'})),
        status: dsm.ServiceStatus.running,
      );
      await apply(sp, service({'args': '-vv'}, ensure: Ensure.stopped));
      expect(backend.calls, ['reconfigure api', 'stop api']);
    });

    test('starts or stops a matching unit in the wrong state', () async {
      final sp = provider();
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(service({})),
        status: dsm.ServiceStatus.stopped,
      );
      expect((await apply(sp, service({}))).reason, 'started and running');
      expect(
        (await apply(sp, service({}, ensure: Ensure.stopped))).reason,
        'stopped',
      );
      expect(backend.calls, ['start api', 'stop api']);
    });

    test('present on an installed unit is a no-op', () async {
      final sp = provider();
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(service({})),
        status: dsm.ServiceStatus.stopped,
      );
      final change = await apply(sp, service({}, ensure: Ensure.present));
      expect(change.kind, ChangeKind.noop);
    });

    test('absent stops and uninstalls', () async {
      final sp = provider();
      backend.units['api'] = InstalledService.of(
        sp.descriptorFor(service({})),
        status: dsm.ServiceStatus.running,
      );
      final change = await apply(sp, service({}, ensure: Ensure.absent));
      expect(change.kind, ChangeKind.remove);
      expect(backend.calls, ['stop api', 'uninstall api']);
    });

    test('a service manager failure is a failed change, not a throw', () async {
      backend.installError = StateError('systemctl: permission denied');
      final change = await apply(provider(), service({}));
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('permission denied'));
    });
  });

  group('health', () {
    test('waits until the check passes', () async {
      probe = ScriptedProbe(['connection refused', 'HTTP 503', null]);
      final change = await apply(
        provider(),
        service({'health_url': 'http://127.0.0.1:8080/health'}),
      );
      expect(change.kind, ChangeKind.create, reason: change.reason);
      expect(probe.asked, hasLength(3));
      expect(probe.asked.first.url.toString(), 'http://127.0.0.1:8080/health');
    });

    test('fails the change when it never passes', () async {
      final change = await apply(
        provider(),
        service({
          'health_cmd': 'curl -fs localhost:8080',
          'health_timeout': '4',
          'health_interval': '1',
        }),
      );
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('installed, but not healthy within 4s'));
      expect(probe.asked, hasLength(5));
      expect(probe.asked.first.command, 'curl -fs localhost:8080');
    });

    test('stops waiting as soon as the process has exited', () async {
      backend.startsAs = dsm.ServiceStatus.failed;
      final change = await apply(
        provider(),
        service({'health_url': 'http://127.0.0.1:1/', 'health_timeout': '60'}),
      );
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, contains('it exited'));
      expect(probe.asked, hasLength(1));
    });

    test('with no check configured, a start is not waited on', () async {
      final change = await apply(provider(), service({}));
      expect(change.kind, ChangeKind.create);
      expect(probe.asked, isEmpty);
    });
  });

  group('refresh', () {
    void installed(ServiceProvider sp, ResolvedResource r) =>
        backend.units[r.id.name] = InstalledService.of(
          sp.descriptorFor(r),
          status: dsm.ServiceStatus.running,
        );

    test('restarts a running service and checks it again', () async {
      probe = ScriptedProbe([null]);
      final sp = provider();
      final r = service({'health_url': 'http://127.0.0.1:8080/'});
      installed(sp, r);
      final change = await sp.refresh(r, context);
      expect(change.kind, ChangeKind.update);
      expect(backend.calls, ['restart api']);
      expect(probe.asked, hasLength(1));
    });

    test('reports an unhealthy restart as failed', () async {
      final sp = provider();
      final r = service({
        'health_url': 'http://127.0.0.1:8080/',
        'health_timeout': '0',
      });
      installed(sp, r);
      final change = await sp.refresh(r, context);
      expect(change.kind, ChangeKind.failed);
      expect(change.reason, startsWith('restarted, but'));
    });

    test('leaves a service declared stopped alone', () async {
      final change = await provider().refresh(
        service({}, ensure: Ensure.stopped),
        context,
      );
      expect(change.kind, ChangeKind.noop);
      expect(backend.calls, isEmpty);
    });
  });

  test('fingerprints ignore environment order, and nothing else', () {
    InstalledService unit(Map<String, String> env, {List<String>? args}) =>
        InstalledService(
          status: dsm.ServiceStatus.running,
          executable: '/x',
          arguments: args ?? const [],
          environment: env,
        );
    expect(
      ServiceProvider.fingerprintOf(unit({'A': '1', 'B': '2'})),
      ServiceProvider.fingerprintOf(unit({'B': '2', 'A': '1'})),
    );
    expect(
      ServiceProvider.fingerprintOf(unit({'A': '1'})),
      isNot(ServiceProvider.fingerprintOf(unit({'A': '2'}))),
    );
    expect(
      ServiceProvider.fingerprintOf(unit({}, args: ['a', 'b'])),
      isNot(ServiceProvider.fingerprintOf(unit({}, args: ['a b']))),
    );
  });
}
