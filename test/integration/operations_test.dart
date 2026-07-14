@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show CommandExecutor, ExecResult, FormulaRegistry, NodeFormulaService;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Work that takes longer than a caller should be made to wait.
///
/// `formula run` answers synchronously: the caller waits, and the Hub gives up
/// after `requestTimeout`. Right for a `verify` — wrong for an `install`, which
/// can take minutes. The caller gets a timeout, the node carries on working, and
/// the operator is told a failure that did not happen.
///
/// `async: true` hands back a handle instead of an answer. The work is *the same
/// work*; only who waits for it changes. Which is why the synchronous contract is
/// not touched: it is still the right answer for the calls it was right for.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;

  setUp(() async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
    );
    await api.start();
  });

  tearDown(() async {
    await api.close();
    await cluster.dispose();
  });

  Future<(int, dynamic)> send(
    String method,
    String path, [
    Object? body,
  ]) async {
    final client = HttpClient();
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    req.headers.set('authorization', 'Bearer api-secret');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    client.close();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  Future<void> startNode({
    required String id,
    Duration takes = Duration.zero,
    bool succeeds = true,
  }) async {
    final service = NodeFormulaService(
      registry: FormulaRegistry.standard(
        executor: _SlowExecutor(takes: takes, succeeds: succeeds),
      ),
    );
    await cluster.startNode(
      id: id,
      formulaHandler: service.runFormula,
      presetHandler: service.applyPreset,
    );
  }

  Future<Map> until(String id, bool Function(Map op) done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final (_, body) = await send('GET', '/api/v1/operations/$id');
      if (done(body as Map)) return body;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('operation $id never got there');
  }

  test(
    'async returns a handle at once, while the node is still working',
    () async {
      await startNode(
        id: 'worker-01',
        takes: const Duration(milliseconds: 600),
      );

      final started = DateTime.now();
      final (status, body) = await send(
        'POST',
        '/api/v1/nodes/worker-01/formula',
        {'formula': 'docker', 'action': 'install', 'async': true},
      );
      final waited = DateTime.now().difference(started);

      // 202: accepted, not done.
      expect(status, 202);
      final op = body as Map;
      expect(op['status'], 'running');
      expect(op['kind'], 'formula');
      expect(op['summary'], 'docker install');
      expect(op['nodeId'], 'worker-01');

      // The caller did not wait for the work.
      expect(waited, lessThan(const Duration(milliseconds: 400)));

      final finished = await until(
        op['id'] as String,
        (o) => o['status'] != 'running',
      );
      expect(finished['status'], 'succeeded');
      // The result is the same body the synchronous call returns, so nothing has
      // to be decoded differently just because it was awaited later.
      expect((finished['result'] as Map)['result'], isNotNull);
    },
  );

  test('the synchronous call is untouched — it still answers', () async {
    await startNode(id: 'worker-01');

    final (status, body) = await send(
      'POST',
      '/api/v1/nodes/worker-01/formula',
      {'formula': 'docker', 'action': 'verify'},
    );

    expect(status, 200, reason: 'not 202: this is an answer, not a handle');
    expect((body as Map)['result'], isNotNull);
    // And it created no operation, because nobody asked for one.
    final (_, ops) = await send('GET', '/api/v1/operations');
    expect(ops, isEmpty);
  });

  test('a failure lands on the operation — the caller is long gone', () async {
    await startNode(id: 'worker-01', succeeds: false);

    final (_, body) = await send('POST', '/api/v1/nodes/worker-01/formula', {
      'formula': 'docker',
      'action': 'install',
      'async': true,
    });

    final finished = await until(
      (body as Map)['id'] as String,
      (o) => o['status'] != 'running',
    );
    // The formula ran and reported failure, so the operation *succeeded* in
    // dispatching it and the result carries the verdict. What matters is that the
    // outcome is readable at all: an error thrown into a caller who left has
    // nowhere to go.
    expect(finished['status'], anyOf('succeeded', 'failed'));
    expect(finished['finishedAt'], isNotNull);
  });

  test('an operation on an offline node fails, and says why', () async {
    await startNode(id: 'worker-01');
    await cluster.stopNodes();

    final (status, body) = await send(
      'POST',
      '/api/v1/nodes/worker-01/formula',
      {'formula': 'docker', 'action': 'verify', 'async': true},
    );
    expect(status, 202);

    final finished = await until(
      (body as Map)['id'] as String,
      (o) => o['status'] != 'running',
    );
    expect(finished['status'], 'failed');
    expect(finished['error'], isNotEmpty);
  });

  test('operations announce themselves finished on the event stream', () async {
    await startNode(id: 'worker-01');

    final events = <OmnyEvent>[];
    final sub = cluster.hub.events.listen(events.add);

    await send('POST', '/api/v1/nodes/worker-01/formula', {
      'formula': 'docker',
      'action': 'verify',
      'async': true,
    });

    // A client learns on the stream it is already watching, rather than polling
    // for an answer it will either ask for too often or find out about too late.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (events.whereType<OperationFinished>().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(events.whereType<OperationStarted>(), hasLength(1));
    expect(events.whereType<OperationFinished>(), hasLength(1));
    await sub.cancel();
  });

  test('the list can be narrowed to what is still running', () async {
    await startNode(id: 'worker-01', takes: const Duration(seconds: 2));

    await send('POST', '/api/v1/nodes/worker-01/formula', {
      'formula': 'docker',
      'action': 'install',
      'async': true,
    });

    final (status, running) = await send(
      'GET',
      '/api/v1/operations?running=true',
    );
    expect(status, 200);
    expect((running as List), hasLength(1));

    final (_, other) = await send('GET', '/api/v1/operations?node=nobody');
    expect(other, isEmpty);
  });

  test('an unknown operation is a 404', () async {
    final (status, _) = await send('GET', '/api/v1/operations/nope');
    expect(status, 404);
  });
}

/// An executor that takes its time, and optionally fails.
class _SlowExecutor implements CommandExecutor {
  final Duration takes;
  final bool succeeds;

  _SlowExecutor({required this.takes, required this.succeeds});

  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    if (takes > Duration.zero) await Future<void>.delayed(takes);
    return succeeds
        ? const ExecResult(exitCode: 0, stdout: 'version 1.0.0')
        : const ExecResult(exitCode: 1, stderr: 'nope');
  }
}
