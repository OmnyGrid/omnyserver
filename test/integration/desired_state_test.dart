@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:omnyserver/omnyserver_node.dart'
    show CommandExecutor, ExecResult, FormulaRegistry, NodeFormulaService;
import 'package:test/test.dart';

import '../support/harness.dart';

/// Desired state: what a node is *supposed* to be, and whether it still is.
///
/// `DesiredState`, `CurrentState`, `StateReconciler` and `DefaultStateReconciler`
/// have existed in the domain from the beginning, wired to nothing at all. These
/// pin what they are for.
///
/// The distinction that matters, and that the API is shaped around: **declaring
/// is not applying**. `PUT /desired-state` runs nothing — it records an intent,
/// so that `GET /drift` can keep answering "is it still true?" afterwards, even
/// after somebody logs into the machine and changes something by hand. Applying a
/// preset and watching it succeed only ever tells you that it succeeded.
void main() {
  late TestCluster cluster;
  late HttpApiServer api;

  /// A node that reports docker as *absent* until a formula installs it — so
  /// drift is a real observation, not a fixture.
  final preset = {
    'id': 'docker-host',
    'name': 'Docker host',
    'steps': [
      {'formula': 'docker', 'action': 'install'},
    ],
  };

  /// Starts a node whose formula engine sees docker as [present], wiring both
  /// handlers: `reconcile` dispatches the plan as a *preset*, so a node with only
  /// a formula handler would receive it and do nothing.
  Future<void> startNode({
    required String id,
    required CommandExecutor executor,
    bool advertisesDocker = false,
  }) async {
    final service = NodeFormulaService(
      registry: FormulaRegistry.standard(executor: executor),
    );
    await cluster.startNode(
      id: id,
      formulaHandler: service.runFormula,
      presetHandler: service.applyPreset,
      capabilityProvider: advertisesDocker
          ? () async => NodeCapabilities(const [
              Capability(kind: CapabilityKind.docker, name: 'docker'),
            ])
          : () async => NodeCapabilities.empty,
    );
  }

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

  test('declaring a state runs nothing on the node', () async {
    var ran = 0;
    await startNode(
      id: 'worker-01',
      executor: _Absent(onRun: () => ran++),
    );

    final (status, body) = await send(
      'PUT',
      '/api/v1/nodes/worker-01/desired-state',
      {'preset': preset},
    );

    expect(status, 200);
    expect((body as Map)['steps'], 1);
    expect(
      ran,
      0,
      reason: 'PUT declares an intent; only reconcile is allowed to act',
    );
  });

  test('a node missing what it was declared to be has drifted', () async {
    await startNode(id: 'worker-01', executor: _Absent());
    await send('PUT', '/api/v1/nodes/worker-01/desired-state', {
      'preset': preset,
    });

    final (status, body) = await send('GET', '/api/v1/nodes/worker-01/drift');

    expect(status, 200);
    expect((body as Map)['converged'], isFalse);
    final actions = (body['actions'] as List).cast<Map>();
    expect(actions, hasLength(1));
    expect(actions.single['formula'], 'docker');
    expect(actions.single['action'], 'install');
  });

  test('a node that already has it has not drifted', () async {
    // The node *advertises* docker, so the install step is already satisfied and
    // the planner drops it. Drift is judged against what a node says it has, not
    // against what it once ran.
    await startNode(
      id: 'worker-01',
      executor: _Present(),
      advertisesDocker: true,
    );
    await send('PUT', '/api/v1/nodes/worker-01/desired-state', {
      'preset': preset,
    });

    final (status, body) = await send('GET', '/api/v1/nodes/worker-01/drift');

    expect(status, 200);
    expect((body as Map)['converged'], isTrue);
    expect(body['actions'], isEmpty);
  });

  test('reconciling a converged node does nothing at all', () async {
    var ran = 0;
    await startNode(
      id: 'worker-01',
      executor: _Present(onRun: () => ran++),
      advertisesDocker: true,
    );
    await send('PUT', '/api/v1/nodes/worker-01/desired-state', {
      'preset': preset,
    });

    final (status, body) = await send(
      'POST',
      '/api/v1/nodes/worker-01/reconcile',
    );

    expect(status, 200);
    expect((body as Map)['results'], isEmpty);
    // Idempotence is what makes this safe on a timer, or in a pipeline.
    expect(ran, 0);
  });

  test('reconciling a drifted node runs the outstanding steps', () async {
    await startNode(id: 'worker-01', executor: _Absent());
    await send('PUT', '/api/v1/nodes/worker-01/desired-state', {
      'preset': preset,
    });

    final (status, body) = await send(
      'POST',
      '/api/v1/nodes/worker-01/reconcile',
    );

    expect(status, 200);
    final results = ((body as Map)['results'] as List).cast<Map>();
    expect(results, hasLength(1), reason: 'the one drifted step ran');
    expect(results.single['formula'], 'docker');
  });

  test('a declaration survives being read back, and can be cleared', () async {
    await startNode(id: 'worker-01', executor: _Present());
    await send('PUT', '/api/v1/nodes/worker-01/desired-state', {
      'preset': preset,
    });

    final (getStatus, body) = await send(
      'GET',
      '/api/v1/nodes/worker-01/desired-state',
    );
    expect(getStatus, 200);
    expect(((body as Map)['steps'] as List).single['formula'], 'docker');

    final (deleteStatus, _) = await send(
      'DELETE',
      '/api/v1/nodes/worker-01/desired-state',
    );
    expect(deleteStatus, 200);

    final (afterStatus, _) = await send(
      'GET',
      '/api/v1/nodes/worker-01/desired-state',
    );
    expect(afterStatus, 404);
  });

  test('a node with nothing declared cannot have drifted', () async {
    await startNode(id: 'worker-01', executor: _Present());
    // Not "converged" — there is nothing to converge *to*, and saying so is more
    // honest than reporting a clean bill of health for a node nobody has made a
    // claim about.
    final (status, body) = await send('GET', '/api/v1/nodes/worker-01/drift');
    expect(status, 404);
    expect((body as Map)['error']['code'], 'not_found');
  });
}

/// A node on which docker is not installed.
class _Absent implements CommandExecutor {
  final void Function()? onRun;

  _Absent({this.onRun});

  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    onRun?.call();
    return const ExecResult(exitCode: 1, stderr: 'not found');
  }
}

/// A node on which docker is already installed.
class _Present implements CommandExecutor {
  final void Function()? onRun;

  _Present({this.onRun});

  @override
  Future<ExecResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    onRun?.call();
    return const ExecResult(exitCode: 0, stdout: 'version 1.0.0');
  }
}
