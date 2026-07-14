@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

import '../support/harness.dart';

/// A node's log, readable without logging into the node.
///
/// Nodes have been able to push log batches from the very first commit, and the
/// Hub decoded each one and **threw it away** ("no log sink yet"). So a node's own
/// log stayed on the node — where the only way to read it is to SSH in, which is
/// the thing a fleet tool exists to avoid.
///
/// What the Hub keeps is a bounded, in-memory *tail*: the last N lines per node,
/// for looking at a machine that is misbehaving right now. It is deliberately not
/// the audit trail (persisted, and answers "who did what"), and deliberately not
/// a log server.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;
  late HttpClient client;

  setUp(() async {
    cluster = await TestCluster.start();
    api = HttpApiServer(
      hub: cluster.hub,
      apiToken: 'api-secret',
      host: '127.0.0.1',
      port: 0,
      eventKeepAlive: const Duration(milliseconds: 200),
    );
    await api.start();
    client = HttpClient();
  });

  tearDown(() async {
    await api.close();
    client.close(force: true);
    await cluster.dispose();
  });

  Future<(int, dynamic)> get(String path) async {
    final http = HttpClient();
    final req = await http.getUrl(
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    req.headers.set('authorization', 'Bearer api-secret');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    http.close();
    return (res.statusCode, body.isEmpty ? null : jsonDecode(body));
  }

  test("a node's lines reach the Hub and can be read back", () async {
    final agent = await cluster.startNode(id: 'worker-01');

    agent.sendLogs(['starting up', 'listening on :8080'], source: 'agent');

    await _until(() async {
      final (_, body) = await get('/api/v1/nodes/worker-01/logs');
      return (body as List).length >= 2;
    });

    final (status, body) = await get('/api/v1/nodes/worker-01/logs');
    expect(status, 200);

    final lines = (body as List).cast<Map>();
    // Oldest first: the order a log is read in.
    expect(lines[0]['message'], 'starting up');
    expect(lines[1]['message'], 'listening on :8080');
    expect(lines[0]['source'], 'agent');
    expect(lines[0]['nodeId'], 'worker-01');
    // Stamped by the Hub's clock, not the node's — a fleet's clocks disagree,
    // and an interleaved tail is unreadable if each node tells a different time.
    expect(DateTime.parse(lines[0]['at'] as String), isA<DateTime>());
  });

  test('one node cannot see another node down the same tail', () async {
    final a = await cluster.startNode(id: 'worker-01');
    final b = await cluster.startNode(id: 'worker-02');

    a.sendLogs(['from one']);
    b.sendLogs(['from two']);

    await _until(() async {
      final (_, body) = await get('/api/v1/nodes/worker-01/logs');
      return (body as List).isNotEmpty;
    });

    final (_, one) = await get('/api/v1/nodes/worker-01/logs');
    final messages = [for (final l in (one as List).cast<Map>()) l['message']];
    expect(messages, contains('from one'));
    expect(messages, isNot(contains('from two')));
  });

  test('tail bounds what comes back', () async {
    final agent = await cluster.startNode(id: 'worker-01');
    agent.sendLogs([for (var i = 0; i < 10; i++) 'line $i']);

    await _until(() async {
      final (_, body) = await get('/api/v1/nodes/worker-01/logs');
      return (body as List).length >= 10;
    });

    final (_, body) = await get('/api/v1/nodes/worker-01/logs?tail=3');
    final lines = (body as List).cast<Map>();
    expect(lines, hasLength(3));
    // The *last* three: a tail is the end of the log, not the start of it.
    expect(lines.last['message'], 'line 9');
  });

  test('the buffer is bounded — an old line is evicted, not kept', () {
    final buffer = LogBuffer(capacityPerNode: 3);
    buffer.record([
      for (var i = 0; i < 5; i++)
        LogLine(
          nodeId: 'worker-01',
          source: 'agent',
          message: 'line $i',
          at: DateTime.utc(2026, 1, 1),
        ),
    ]);

    final lines = buffer.recentFor('worker-01');
    expect(lines, hasLength(3));
    expect([for (final l in lines) l.message], ['line 2', 'line 3', 'line 4']);
  });

  test('a node that has said nothing has an empty tail, not a 404', () async {
    await cluster.startNode(id: 'worker-01');
    final (status, body) = await get('/api/v1/nodes/worker-01/logs');
    // Most nodes are quiet. A 404 here would say something untrue about the node.
    expect(status, 200);
    expect(body, isEmpty);
  });

  test('an unknown node is a 404', () async {
    final (status, _) = await get('/api/v1/nodes/ghost/logs');
    expect(status, 404);
  });

  test('the log can be followed, live', () async {
    final agent = await cluster.startNode(id: 'worker-01');

    final req = await client.getUrl(
      Uri.parse(
        'http://127.0.0.1:${api.boundPort}/api/v1/nodes/worker-01/logs/stream',
      ),
    );
    req.headers.set('authorization', 'Bearer api-secret');
    final res = await req.close();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'text/event-stream');

    final lines = <String>[];
    res
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add, onError: (_) {}, cancelOnError: true);

    // Reported *after* the stream is open: this is a tail, not a replay.
    agent.sendLogs(['something happened']);

    await _until(
      () async => lines.any((l) => l.contains('something happened')),
    );
    expect(lines, contains('event: log'));
  });
}

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('condition not met before timeout');
}
