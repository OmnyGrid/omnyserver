@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyshell/omnyshell_hub.dart' as omnyshell;
import 'package:test/test.dart';

void main() {
  final grants = {
    'tok': TokenGrant(principal: PrincipalId('alice'), roles: const {'admin'}),
  };

  group('ShellHub AI proxy', () {
    test('no aiConfig means the broker serves no AI', () {
      final hub = ShellHub.fromGrants(grants);
      expect(
        hub.broker.aiProxy,
        isNull,
        reason: 'without a config the web :ai has no Hub default',
      );
    });

    test('an aiConfig wires the broker proxy', () {
      final hub = ShellHub.fromGrants(
        grants,
        aiConfig: const omnyshell.AiConfig(
          provider: omnyshell.AiProviderKind.anthropic,
          model: 'claude-opus-4-8',
          apiKey: 'sk-secret',
        ),
      );
      expect(
        hub.broker.aiProxy,
        isNotNull,
        reason: 'the broker answers fetchHubAiConfig and proxies :ai calls',
      );
    });
  });
}
