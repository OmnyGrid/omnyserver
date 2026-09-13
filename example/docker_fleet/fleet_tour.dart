// Drives the container fleet from `compose.yaml` through the Hub's REST API:
// what is out there, what each host can do, and what happens when you ask it
// to do something.
//
// Bring the fleet up first, from the repository root:
//
//   docker compose -f example/docker_fleet/compose.yaml up --build -d
//   dart run example/docker_fleet/fleet_tour.dart
//   docker compose -f example/docker_fleet/compose.yaml down -v
//
// Everything here goes over TLS, verified against the fleet's own CA — the
// same API a dashboard or a deploy script would call.
import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';

/// Where `compose.yaml` lives, so this can be run from anywhere.
final String _composeFile = Platform.script
    .resolve('compose.yaml')
    .toFilePath();

Future<void> main() async {
  // The CA the fleet issued itself lives in a volume. Copy it out of the
  // running Hub rather than asking you to keep a copy on your machine.
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
    await _addressingIt(hub);
    await _workOnAHost(hub);
    await _desiredState(hub);
    await _credentials(hub);
    await _whatHappened(hub);
  } finally {
    hub.close();
    ca.parent.deleteSync(recursive: true);
  }
}

/// 1. Who is out there, and what each host turned out to have.
Future<void> _theFleet(HubApiClient hub) async {
  _heading('The fleet');

  // Containers start in parallel and register when they are ready, so wait
  // rather than assume.
  final nodes = await _eventually(
    () async => (await hub.get('/nodes') as List).cast<Map>(),
    (nodes) => nodes.length >= 3 && nodes.every((n) => n['online'] == true),
    what: 'all three nodes to register',
  );

  for (final node in nodes) {
    final labels = (node['labels'] as Map).entries
        .map((e) => '${e.key}=${e.value}')
        .join(' ');
    // Capability detection ran on each node's own host: the builder found a
    // Dart SDK because it has one, and the workers found nothing because they
    // have nothing.
    final capabilities =
        ((node['capabilities'] as Map?)?['capabilities'] as List? ?? const [])
            .map((c) => (c as Map)['name'])
            .join(', ');
    print(
      '  ${(node['nodeId'] as String).padRight(10)} '
      '${(node['platform'] as Map)['osName']}  '
      '[$labels]  '
      'can: ${capabilities.isEmpty ? '(nothing installed)' : capabilities}',
    );
  }
}

/// 2. Addressing the fleet by what a node *is*, not by where it is.
Future<void> _addressingIt(HubApiClient hub) async {
  _heading('Selecting by label');

  for (final selector in ['env=prod', 'region=eu', 'role=builder']) {
    final matched = (await hub.get('/nodes?label=$selector') as List)
        .cast<Map>()
        .map((n) => n['nodeId'])
        .join(', ');
    print('  ${selector.padRight(14)} -> $matched');
  }
}

/// 3. Work happens on the node, on its own machine.
Future<void> _workOnAHost(HubApiClient hub) async {
  _heading('Running a formula');

  // The same request to two hosts, with two different answers — which is the
  // point: the Hub did not run this, the node did.
  for (final node in ['builder-1', 'worker-1']) {
    final reply =
        await hub.post('/nodes/$node/formula', {
              'formula': 'dart',
              'action': 'verify',
            })
            as Map;
    final result = reply['result'] as Map;
    print(
      '  dart verify on ${node.padRight(10)} '
      '${result['success'] == true ? 'ok' : 'no'} '
      '— ${result['message']}',
    );
  }
}

/// 4. Declaring what a node should be, and asking how far it has drifted.
Future<void> _desiredState(HubApiClient hub) async {
  _heading('Desired state');

  // One thing the host already has and one it does not, so the answer below
  // has something to say either way.
  await hub.put('/nodes/builder-1/desired-state', {
    'steps': [
      {'formula': 'dart', 'action': 'verify'},
      {'formula': 'docker', 'action': 'verify'},
    ],
  });
  print('  builder-1 is declared to be: dart, docker');

  // Nothing has run: this is a question about the node, not an instruction.
  final drift = await hub.get('/nodes/builder-1/drift') as Map;
  print(
    '  converged: ${drift['converged']}'
    '${drift['converged'] == true ? '' : ' — would run: '
              '${(drift['actions'] as List).map((a) => (a as Map)['formula']).join(', ')}'}',
  );
  for (final note in (drift['notes'] as List? ?? const [])) {
    print('    - $note');
  }
}

/// 5. Issuing a credential, and taking it away again.
Future<void> _credentials(HubApiClient hub) async {
  _heading('Credentials');

  final grant =
      await hub.post('/grants', {
            'principal': 'ci',
            'roles': ['viewer'],
            'note': 'the fleet tour',
          })
          as Map;
  // Shown once, and once only: the Hub keeps a hash, not the token.
  print('  issued ${grant['id']} for ci (viewer)');

  final asCi = HubApiClient(
    Uri.parse('https://127.0.0.1:8443'),
    principal: 'ci',
    token: grant['token'] as String,
    transport: IoApiTransport(
      securityContext: SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(_caPath),
    ),
  );
  try {
    print(
      '  as ci: sees ${(await asCi.get('/nodes') as List).length} nodes, '
      'and cannot restart one: '
      '${await _refused(() => asCi.post('/nodes/worker-1/restart'))}',
    );
  } finally {
    asCi.close();
  }

  await hub.delete('/grants/${grant['id']}');
  print('  revoked — that token is now refused');
}

/// 6. What the Hub recorded while this ran.
Future<void> _whatHappened(HubApiClient hub) async {
  _heading('Audit trail');

  final entries = (await hub.get('/audit') as List).cast<Map>();
  for (final entry in entries.take(8)) {
    print(
      '  ${entry['at']}  ${(entry['principal'] as String).padRight(6)} '
      '${(entry['action'] as String).padRight(16)} '
      '${entry['target'] ?? ''} ${entry['outcome']}',
    );
  }

  print('\nBring it down with:');
  print('  docker compose -f example/docker_fleet/compose.yaml down -v');
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

late String _caPath;

/// Copies the fleet's CA certificate out of the running Hub container.
Future<File> _copyCaFromHub() async {
  final dir = Directory.systemTemp.createTempSync('omnyserver-fleet-tour');
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
      '  docker compose -f example/docker_fleet/compose.yaml up --build -d\n'
      '${result.stderr}',
    );
    exit(1);
  }
  _caPath = ca.path;
  return ca;
}

/// Describes how a request was refused, for a line of output.
Future<String> _refused(Future<dynamic> Function() request) async {
  try {
    await request();
    return 'it was allowed (unexpected)';
  } on HubApiException catch (e) {
    return '${e.statusCode} ${e.message}';
  }
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
