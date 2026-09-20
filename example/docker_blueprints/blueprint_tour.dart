// Walks the fleet from `compose.yaml` through everything a blueprint is for:
// composing from a shared preset, planning against a real machine, applying,
// staying converged, following an edit to a shared piece, and removing what a
// blueprint has stopped declaring.
//
// Bring the fleet up first, from the repository root:
//
//   docker compose -f example/docker_blueprints/compose.yaml up --build -d
//   dart run example/docker_blueprints/blueprint_tour.dart
//   docker compose -f example/docker_blueprints/compose.yaml down -v
//
// Worth having http://localhost:8080 open while it runs: each node's
// **Declared state** card shows the same plan this prints, and the **Log**
// button follows an install while it happens.
//
// Everything goes over TLS, verified against the fleet's own CA — the same API
// a dashboard or a deploy script would call.
import 'dart:convert';
import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';

/// Where this example's files live, so it can be run from anywhere.
final Uri _here = Platform.script.resolve('.');

final String _composeFile = _here.resolve('compose.yaml').toFilePath();

Future<void> main() async {
  final ca = await _copyCaFromHub();

  final hub = HubApiClient(
    Uri.parse('https://127.0.0.1:8443'),
    principal: 'alice',
    token: 'admin-token',
    transport: IoApiTransport(
      securityContext: SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(ca.path),
    ),
  );

  try {
    await _theFleet(hub);
    await _theLibrary(hub);
    await _assign(hub);
    await _planBeforeAnything(hub);
    await _apply(hub);
    await _applyAgain(hub);
    await _stopDeclaringSomething(hub);
    await _editTheSharedPreset(hub);
    await _whatHappened(hub);
  } finally {
    hub.close();
    ca.parent.deleteSync(recursive: true);
  }
}

/// 1. Three empty machines.
Future<void> _theFleet(HubApiClient hub) async {
  _heading('The fleet, before anything is declared');

  final nodes = await _eventually(
    () async => (await hub.get('/nodes') as List).cast<Map>(),
    (nodes) => nodes.length >= 3 && nodes.every((n) => n['online'] == true),
    what: 'all three nodes to register',
  );

  for (final node in nodes) {
    final labels = (node['labels'] as Map).entries
        .map((e) => '${e.key}=${e.value}')
        .join(' ');
    print('  ${(node['nodeId'] as String).padRight(9)} [$labels]');
  }
}

/// 2. One preset, two blueprints, and what they flatten into.
Future<void> _theLibrary(HubApiClient hub) async {
  _heading('The library');

  // A preset is JSON; a blueprint is whichever format it was written in, and
  // these two were written as YAML. `BlueprintFile.read` is what the CLI's
  // `blueprint save` uses.
  await hub.post('/presets', await _json('presets/base-tools.json'));
  print('  preset    base-tools   (procps, net-tools)');

  for (final name in ['web-server', 'build-host']) {
    final blueprint = await BlueprintFile.read(
      _here.resolve('blueprints/$name.yaml').toFilePath(),
    );
    await hub.post('/blueprints', blueprint.toJson());
    print(
      '  blueprint ${name.padRight(12)} '
      'includes ${blueprint.includes.length}, '
      'declares ${blueprint.resources.length} of its own',
    );
  }

  // Flattened: the includes expanded in place, everything in the order it will
  // be settled, and each resource naming the document that asked for it. This
  // is exactly what a node is sent.
  print('\n  build-host, resolved:');
  final resolved = await hub.get('/blueprints/build-host/resolved') as Map;
  for (final r in (resolved['resources'] as List).cast<Map>()) {
    print(
      '    ${'${r['type']}:${r['name']}'.padRight(22)} '
      '${'${r['ensure']}'.padRight(10)} from ${r['origin']}',
    );
  }
  print('    ${resolved['hash']}');
}

/// 3. Assigning by what a machine is for, not by its name.
Future<void> _assign(HubApiClient hub) async {
  _heading('Assigning');

  for (final (selector, blueprint) in [
    ('role=web', 'web-server'),
    ('role=build', 'build-host'),
  ]) {
    final nodes = (await hub.get('/nodes?label=$selector') as List)
        .cast<Map>()
        .map((n) => n['nodeId'] as String)
        .toList();
    for (final node in nodes) {
      await hub.put('/nodes/$node/desired-state', {'blueprint': blueprint});
    }
    print('  $selector -> $blueprint  (${nodes.join(', ')})');
  }

  // Nothing has run. Declaring and applying are separate on purpose: you can
  // say what a machine should be before you are ready to change it.
  print('\n  Nothing has run yet — assigning is a claim, not an instruction.');
}

/// 4. What each node says it would take. The *node* says it.
Future<void> _planBeforeAnything(HubApiClient hub) async {
  _heading('The plan');

  for (final node in ['web-1', 'build-1']) {
    final drift = await hub.get('/nodes/$node/drift') as Map;
    print(
      '  $node — ${drift['converged'] == true ? 'converged' : 'drifted'} '
      'from ${drift['blueprint']}',
    );
    for (final change in (drift['changes'] as List).cast<Map>()) {
      print(
        '    ${'${change['kind']}'.padRight(8)} '
        '${'${change['resource']}'.padRight(22)} '
        '${'${change['reason']}'.padRight(24)} from ${change['origin']}',
      );
    }
  }

  // The interesting line above is `formula:dart noop` on build-1: the image
  // already has a Dart SDK, so the blueprint asks for something already true.
  print(
    '\n  build-1 already had Dart, so nothing is planned for it — and when\n'
    '  the apply runs, the node will record it as adopted rather than owned.',
  );
}

/// 5. Making it so. This is where the machines actually change.
Future<void> _apply(HubApiClient hub) async {
  _heading('Applying (this installs real packages — give it a minute)');

  for (final node in ['web-1', 'web-2', 'build-1']) {
    final result = await hub.post('/nodes/$node/reconcile', const {}) as Map;
    print(
      '  ${node.padRight(9)} ${result['success'] == true ? 'ok ' : 'FAILED'} '
      '— ${result['changed']} changed, ${result['skipped']} skipped',
    );
    for (final change in (result['changes'] as List).cast<Map>()) {
      if (change['kind'] == 'noop') continue;
      print('    ${'${change['kind']}'.padRight(8)} ${change['resource']}');
    }
  }
}

/// 6. The property everything else rests on.
Future<void> _applyAgain(HubApiClient hub) async {
  _heading('Converged, and idempotent');

  for (final node in ['web-1', 'build-1']) {
    final drift = await hub.get('/nodes/$node/drift') as Map;
    final again = await hub.post('/nodes/$node/reconcile', const {}) as Map;
    print(
      '  ${node.padRight(9)} converged: ${drift['converged']}, '
      'and applying again changed ${again['changed']}',
    );
  }

  print(
    '\n  Applying twice does nothing the second time, because every resource\n'
    '  declares what it should *be*. That is also why drift detection is the\n'
    '  same comparison with the apply left off.',
  );
}

/// 7. The two things only a ledger can do, and they are different things.
Future<void> _stopDeclaringSomething(HubApiClient hub) async {
  _heading('Removing resources from a blueprint');

  // Both blueprints stop declaring something. In each case the document no
  // longer mentions it — so the document cannot ask for it to go. Only the
  // node's record of what was applied last time can.
  //
  // The two are not treated alike, and that is the point:
  //
  //   nmap on web-1    this blueprint installed it, so it is removed.
  //   dart on build-1  the machine already had it, so the node adopted it
  //                    rather than claiming it. It is released and left exactly
  //                    where it is — we never owned that SDK.
  await hub.post('/blueprints', {
    'blueprint': 'web-server',
    'name': 'Web server',
    'platforms': ['linux'],
    'includes': ['base-tools'],
    'resources': [
      {'type': 'formula', 'name': 'dns-utils', 'ensure': 'installed'},
    ],
  });
  await hub.post('/blueprints', {
    'blueprint': 'build-host',
    'name': 'Build host',
    'platforms': ['linux'],
    'includes': ['base-tools'],
    'resources': [
      {'type': 'formula', 'name': 'build-tools', 'ensure': 'installed'},
    ],
  });
  print('  web-server drops nmap, which it installed.');
  print('  build-host drops dart, which the machine already had.\n');

  for (final node in ['web-1', 'build-1']) {
    final drift = await hub.get('/nodes/$node/drift') as Map;
    for (final change in (drift['changes'] as List).cast<Map>()) {
      if (change['kind'] == 'noop') continue;
      print(
        '  ${node.padRight(9)} ${'${change['kind']}'.padRight(7)} '
        '${'${change['resource']}'.padRight(20)} ${change['reason']}',
      );
    }
    for (final note in (drift['notes'] as List? ?? const [])) {
      print('  ${node.padRight(9)} left    $note');
    }
  }

  print('');
  for (final node in ['web-1', 'build-1']) {
    final result = await hub.post('/nodes/$node/reconcile', const {}) as Map;
    print('  ${node.padRight(9)} applied: ${result['changed']} changed');
  }

  // What each node has now, probed on the node itself rather than believed by
  // the Hub. nmap is gone; the Dart SDK is exactly where it was.
  print('');
  for (final (node, formula) in [('web-1', 'nmap'), ('build-1', 'dart')]) {
    final onTheBox = (await hub.get('/nodes/$node/formulas') as List)
        .cast<Map>();
    final status = onTheBox.firstWhere(
      (f) => f['formula'] == formula,
    )['status'];
    print('  ${node.padRight(9)} $formula: $status');
  }
}

/// 8. The sharing dividend, and the sharing hazard: one coin.
Future<void> _editTheSharedPreset(HubApiClient hub) async {
  _heading('Editing the shared preset');

  // Neither blueprint is touched, and neither node is contacted. An include
  // names a preset and follows it, so this one edit reaches both kinds of
  // machine — which is why sharing is worth it, and why it deserves care.
  await hub.post('/presets', {
    'id': 'base-tools',
    'name': 'Base tools',
    'steps': [
      {'formula': 'procps', 'action': 'install'},
      {'formula': 'net-tools', 'action': 'install'},
      {'formula': 'nmap', 'action': 'install'},
    ],
  });
  print('  base-tools gains nmap. Nothing else was edited.\n');

  for (final node in ['web-1', 'build-1']) {
    final drift = await hub.get('/nodes/$node/drift') as Map;
    final pending = (drift['changes'] as List)
        .cast<Map>()
        .where((c) => c['kind'] != 'noop')
        .map((c) => '${c['kind']} ${c['resource']}')
        .join(', ');
    print(
      '  ${node.padRight(9)} '
      '${drift['converged'] == true ? 'converged' : 'drifted'}'
      '${pending.isEmpty ? '' : ' — $pending'}',
    );
  }

  print('\n  Converging both:');
  for (final node in ['web-1', 'build-1']) {
    final result = await hub.post('/nodes/$node/reconcile', const {}) as Map;
    print('    ${node.padRight(9)} ${result['changed']} changed');
  }
}

/// 9. What the Hub recorded while this ran.
Future<void> _whatHappened(HubApiClient hub) async {
  _heading('Audit trail');

  final entries = (await hub.get('/audit') as List).cast<Map>();
  for (final entry in entries.take(10)) {
    print(
      '  ${(entry['principal'] as String).padRight(6)} '
      '${(entry['action'] as String).padRight(18)} '
      '${'${entry['target'] ?? ''}'.padRight(12)} ${entry['detail'] ?? ''}',
    );
  }

  print('\nBring it down with:');
  print('  docker compose -f example/docker_blueprints/compose.yaml down -v');
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

/// Reads one of this example's JSON files.
Future<Map<String, dynamic>> _json(String relative) async {
  final file = File(_here.resolve(relative).toFilePath());
  return (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>();
}

/// Copies the fleet's CA certificate out of the running Hub container.
Future<File> _copyCaFromHub() async {
  final dir = Directory.systemTemp.createTempSync('omnyserver-blueprint-tour');
  final ca = File('${dir.path}/ca.crt');

  final result = await Process.run('docker', [
    'compose',
    '-f',
    _composeFile,
    'cp',
    'hub:/certs/ca.crt',
    ca.path,
  ]);
  if (result.exitCode != 0 || !ca.existsSync()) {
    stderr.writeln(
      'Could not read the fleet CA — is the fleet up?\n'
      '  docker compose -f example/docker_blueprints/compose.yaml up --build -d'
      '\n${result.stderr}',
    );
    exit(1);
  }
  return ca;
}

/// Polls [request] until [until] holds, because a fleet converges.
Future<T> _eventually<T>(
  Future<T> Function() request,
  bool Function(T value) until, {
  required String what,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final value = await request();
      if (until(value)) return value;
    } on Object {
      // The Hub may still be coming up; keep asking until the deadline.
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  stderr.writeln('Gave up waiting for $what after $timeout.');
  exit(1);
}

void _heading(String title) => print('\n$title\n${'-' * title.length}');
