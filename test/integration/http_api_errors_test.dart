@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// The API's refusals.
///
/// A 404 and a 400 are answers, and the message is what a caller acts on — so
/// each of these asserts the status *and* that the body names the thing that
/// was wrong. A bare "error" sends the next person to the Hub's logs.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late HubApiClient client;

  setUp(() async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
    client = HubApiClient(
      Uri.parse('http://127.0.0.1:${api.boundPort}'),
      token: 'api-secret',
    );
  });

  tearDown(() async {
    client.close();
    await api.close();
    await cluster.dispose();
  });

  /// Expects [call] to fail with [status], and to say [says] while doing it.
  Matcher refusal(int status, String says) => throwsA(
    isA<HubApiException>()
        .having((e) => e.statusCode, 'status', status)
        .having((e) => e.message, 'message', contains(says)),
  );

  group('bad requests name the missing field', () {
    test('running a formula without naming one', () async {
      await cluster.startNode(id: 'worker-01');
      await expectLater(
        client.post('/nodes/worker-01/formula', const {'action': 'verify'}),
        refusal(400, 'formula is required'),
      );
    });

    test('issuing a grant without a principal', () async {
      await expectLater(
        client.post('/grants', const {
          'roles': ['operator'],
        }),
        refusal(400, 'principal is required'),
      );
    });

    test('issuing a grant with no roles at all', () async {
      await expectLater(
        client.post('/grants', const {'principal': 'bob'}),
        refusal(400, 'roles are required'),
      );
    });
  });

  group('not-found answers name what was not found', () {
    test('deleting a preset that was never saved', () async {
      await expectLater(
        client.delete('/presets/never-saved'),
        refusal(404, 'never-saved'),
      );
    });

    test('revoking a grant that does not exist', () async {
      await expectLater(
        client.delete('/grants/grant-nope'),
        refusal(404, 'grant-nope'),
      );
    });

    test('declaring desired state for a node the Hub has never seen', () async {
      await expectLater(
        client.put('/nodes/ghost-01/desired-state', const {
          'steps': [
            {'formula': 'docker', 'action': 'verify'},
          ],
        }),
        refusal(404, 'ghost-01'),
      );
    });

    test('clearing desired state that was never declared', () async {
      await cluster.startNode(id: 'worker-01');
      await expectLater(
        client.delete('/nodes/worker-01/desired-state'),
        refusal(404, 'worker-01'),
      );
    });
  });

  group('the metrics window', () {
    setUp(() async {
      await cluster.startNode(id: 'worker-01');
      // A node is in the history only once it has reported.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (true) {
        try {
          await client.get('/nodes/worker-01/status');
          break;
        } on HubApiException catch (e) {
          if (e.statusCode != 404 || DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
    });

    test('accepts every shorthand unit, and an absolute instant', () async {
      for (final since in const ['90s', '15m', '1h', '7d']) {
        expect(
          await client.get('/nodes/worker-01/metrics?since=$since'),
          isA<List<dynamic>>(),
          reason: since,
        );
      }
      final iso = DateTime.utc(2020).toIso8601String();
      expect(
        await client.get('/nodes/worker-01/metrics?since=$iso'),
        isA<List<dynamic>>(),
      );
    });

    test('a window that has not started yet holds nothing', () async {
      final future = DateTime.now().toUtc().add(const Duration(days: 1));
      expect(
        await client.get(
          '/nodes/worker-01/metrics?since=${future.toIso8601String()}',
        ),
        isEmpty,
      );
    });
  });
}
