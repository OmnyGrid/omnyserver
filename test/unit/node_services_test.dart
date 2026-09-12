@TestOn('vm')
library;

import 'package:dart_service_manager/dart_service_manager.dart' as dsm;
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

/// Stands in for the platform's service manager (systemd / launchd / SCM), so
/// the tests exercise the routing and failure handling without installing
/// anything on the machine running them.
class _FakeManager implements dsm.DartServiceManager {
  final List<String> calls = [];

  /// What [status] reports back.
  dsm.ServiceStatus reported = dsm.ServiceStatus.running;

  /// When set, every lifecycle call throws it.
  Object? failure;

  void _record(String call) {
    calls.add(call);
    if (failure != null) throw failure!;
  }

  @override
  Future<void> install(
    String packageName, {
    String? serviceName,
    dsm.ServiceScope scope = dsm.ServiceScope.user,
    String? path,
    bool force = false,
  }) async => _record('install:$serviceName');

  @override
  Future<void> uninstall(String packageName, {String? serviceName}) async =>
      _record('uninstall:$serviceName');

  @override
  Future<void> start(String packageName, String serviceName) async =>
      _record('start:$serviceName');

  @override
  Future<void> stop(String packageName, String serviceName) async =>
      _record('stop:$serviceName');

  @override
  Future<void> restart(String packageName, String serviceName) async =>
      _record('restart:$serviceName');

  @override
  Future<dsm.ServiceStatus> status(
    String packageName,
    String serviceName,
  ) async => reported;

  // Everything else on the manager is out of scope here.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('ServiceController', () {
    late _FakeManager manager;
    late ServiceController controller;

    setUp(() {
      manager = _FakeManager();
      controller = ServiceController(manager: manager);
    });

    test('each lifecycle call reaches the platform manager', () async {
      await controller.install('hub');
      await controller.start('hub');
      await controller.stop('hub');
      await controller.restart('hub');
      await controller.uninstall('hub');

      expect(manager.calls, [
        'install:hub',
        'start:hub',
        'stop:hub',
        'restart:hub',
        'uninstall:hub',
      ]);
    });

    // The platforms disagree about how many states a service has; OmnyServer
    // reports four, and this is where the rest are folded into them.
    test('platform states are mapped onto the four we report', () async {
      Future<ServiceStatus> statusFor(dsm.ServiceStatus reported) async {
        manager.reported = reported;
        return (await controller.describe('hub')).status;
      }

      expect(await statusFor(dsm.ServiceStatus.running), ServiceStatus.running);
      // Installed-but-not-running and paused are both "stopped" to an operator.
      expect(await statusFor(dsm.ServiceStatus.stopped), ServiceStatus.stopped);
      expect(await statusFor(dsm.ServiceStatus.paused), ServiceStatus.stopped);
      expect(
        await statusFor(dsm.ServiceStatus.installed),
        ServiceStatus.stopped,
      );
      // A failed service is one we cannot speak for — not one we call stopped.
      expect(await statusFor(dsm.ServiceStatus.failed), ServiceStatus.unknown);
      // A platform that reports nothing usable is read as nothing installed.
      expect(
        await statusFor(dsm.ServiceStatus.unknown),
        ServiceStatus.notInstalled,
      );
    });

    test('autoStart follows being installed, not being up', () async {
      manager.reported = dsm.ServiceStatus.installed;
      expect((await controller.describe('hub')).autoStart, isTrue);

      manager.reported = dsm.ServiceStatus.stopped;
      expect(
        (await controller.describe('hub')).autoStart,
        isFalse,
        reason: 'explicitly stopped is not set to start at boot',
      );
    });
  });

  group('NodeServiceHandler', () {
    late _FakeManager manager;
    late NodeServiceHandler handler;

    setUp(() {
      manager = _FakeManager();
      handler = NodeServiceHandler(ServiceController(manager: manager));
    });

    Future<ServiceControlResult> control(String action) => handler.handle(
      ServiceControl(requestId: 'r1', service: 'hub', action: action),
    );

    test('routes each action and reports the resulting state', () async {
      for (final action in ['install', 'start', 'stop', 'restart']) {
        final result = await control(action);
        expect(result.success, isTrue, reason: action);
        expect(result.requestId, 'r1');
        expect(result.descriptor?.status, ServiceStatus.running);
      }
      expect(manager.calls, [
        'install:hub',
        'start:hub',
        'stop:hub',
        'restart:hub',
      ]);
    });

    test('an unknown action is refused, and says so', () async {
      final result = await control('teleport');
      expect(result.success, isFalse);
      expect(result.message, contains('unknown service action "teleport"'));
      expect(manager.calls, isEmpty, reason: 'nothing was attempted');
    });

    // A node is a long-running agent: a failed systemctl has to come back as a
    // failed request, not as an exception that takes the agent down.
    test(
      'a failing platform call becomes a failed result, not a throw',
      () async {
        manager.failure = StateError('systemctl: unit not found');
        final result = await control('restart');

        expect(result.success, isFalse);
        expect(result.message, contains('service restart failed'));
        expect(result.message, contains('unit not found'));
        expect(result.descriptor, isNull);
      },
    );
  });

  group('LogShipper', () {
    test('ships a batch once it has enough lines', () {
      final sent = <List<String>>[];
      final shipper = LogShipper(send: sent.add, maxLines: 3);

      shipper.add('one');
      shipper.add('two');
      expect(sent, isEmpty, reason: 'still filling the batch');

      shipper.add('three');
      expect(sent, hasLength(1));
      expect(sent.single, ['one', 'two', 'three']);
    });

    test('ships what is waiting when the interval passes', () async {
      final sent = <List<String>>[];
      final shipper = LogShipper(
        send: sent.add,
        maxLines: 100,
        interval: const Duration(milliseconds: 20),
      );

      shipper.add('one');
      // A tail that only arrives once 100 lines have piled up is not a tail.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sent.single, ['one']);
    });

    test('an empty flush sends nothing at all', () {
      final sent = <List<String>>[];
      LogShipper(send: sent.add).flush();
      expect(sent, isEmpty);
    });

    // The documented trade: a node's log tail is about what is happening now,
    // so a batch that cannot be delivered is dropped rather than queued — an
    // agent that queues forever eventually eats the machine.
    test('a send that throws drops the batch instead of growing it', () {
      var attempts = 0;
      final shipper = LogShipper(
        send: (_) {
          attempts++;
          throw StateError('link down');
        },
        maxLines: 2,
      );

      shipper.add('one');
      shipper.add('two');
      shipper.add('three');
      shipper.add('four');

      expect(attempts, 2, reason: 'each full batch was attempted once');
      // Nothing was retained: the next batch carries only new lines.
      expect(() => shipper.close(), returnsNormally);
    });

    test('close ships the tail, then stops accepting lines', () {
      final sent = <List<String>>[];
      final shipper = LogShipper(send: sent.add, maxLines: 100);

      shipper.add('one');
      shipper.close();
      expect(sent.single, ['one'], reason: 'the tail was not abandoned');

      shipper.add('after');
      shipper.flush();
      expect(sent, hasLength(1), reason: 'a closed shipper ships nothing more');
    });
  });
}
