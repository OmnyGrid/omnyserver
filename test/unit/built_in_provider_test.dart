@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

/// The Hub validates blueprints against [BuiltInProvider]; the node's
/// providers answer from it. These pin the two to each other.
void main() {
  test('looks a type up by its blueprint name', () {
    expect(BuiltInProvider.byType('release'), BuiltInProvider.release);
    expect(BuiltInProvider.byType('service'), BuiltInProvider.service);
    expect(BuiltInProvider.byType('formula'), isNull);
    expect(BuiltInProvider.byType('Release'), isNull);
  });

  test('a release is never running; a service can be', () {
    expect(BuiltInProvider.release.supportedEnsure, {
      Ensure.present,
      Ensure.installed,
      Ensure.absent,
    });
    expect(BuiltInProvider.service.supportedEnsure, contains(Ensure.running));
    expect(BuiltInProvider.service.supportedEnsure, contains(Ensure.stopped));
    expect(
      BuiltInProvider.service.supportedEnsure,
      isNot(contains(Ensure.latest)),
    );
  });

  test('the node providers answer exactly what the Hub checks', () {
    final release = ReleaseProvider(allowedRoots: const []);
    expect(release.type, BuiltInProvider.release.type);
    expect(release.supportedEnsure, BuiltInProvider.release.supportedEnsure);

    final service = ServiceProvider(
      backend: _NoBackend(),
      runningAsRoot: false,
      canSwitchUser: false,
    );
    expect(service.type, BuiltInProvider.service.type);
    expect(service.supportedEnsure, BuiltInProvider.service.supportedEnsure);
  });
}

/// Never called: the test only reads the provider's identity.
class _NoBackend implements ServiceBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used');
}
