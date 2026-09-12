import 'dart:io';

import 'package:docker_commander/docker_commander_vm.dart';
import 'package:omnyserver/omnyserver_cli.dart';
import 'package:omnyserver/omnyserver_hub.dart' show CertGenerator;
import 'package:test/test.dart';

/// A Hub and its nodes, each in its own container, on a private Docker network.
///
/// The in-process suite runs a Hub and its agents in one isolate over loopback:
/// fast, and blind to everything the network does. These tests give up that
/// speed to get the parts it cannot reach — a real TLS handshake against a
/// certificate issued for a hostname, DNS between containers, a process that
/// can be killed and restarted, and a host whose installed software the node
/// has to discover for itself.
///
/// Every test here is skipped, not failed, where no Docker daemon is reachable.
class OmnyFleet {
  /// How long a container has to come up before a test gives up on it.
  static const Duration readyTimeout = Duration(seconds: 60);

  /// The image tags built from `test/docker/Dockerfile`.
  static const String runtimeImage = 'omnyserver-test:runtime';
  static const String sdkImage = 'omnyserver-test:sdk';

  /// The Hub's role name, used for its container and its hostname.
  static const String hubHost = 'hub';

  /// The Hub's port inside the network.
  static const int hubPort = 8443;

  /// The API token the Hub is started with.
  static const String apiToken = 'api-secret';

  /// The node credential the Hub is started with.
  static const String nodeToken = 'node-token';

  /// The operator credential the Hub is started with.
  static const String operatorToken = 'admin-token';

  final DockerCommander docker;
  final String network;

  /// Host directory holding the dev CA and the Hub's certificate, mounted into
  /// every container at `/certs`.
  final Directory certs;

  /// The host port the Hub's published port is reachable on.
  final int publishedPort;

  final List<DockerContainer> _containers = [];
  DockerContainer? _hub;

  OmnyFleet._(this.docker, this.network, this.certs, this.publishedPort);

  /// The name the other containers dial the Hub by.
  ///
  /// Docker's embedded DNS on a user-defined network resolves *container
  /// names*, so this — not the bare `hub` hostname — is what has to appear in
  /// the certificate, and what the nodes are pointed at.
  String get hubDnsName => '$network-$hubHost';

  /// The Hub's `wss://` URL from inside the network.
  String get hubUri => 'wss://$hubDnsName:$hubPort';

  /// The Hub's API URL from inside the network.
  String get hubApiUri => 'https://$hubDnsName:$hubPort';

  /// Whether the images have been built in this process yet.
  static bool _imagesBuilt = false;

  /// Why Docker cannot be used here, or null when it can.
  ///
  /// Checked once per process: an unreachable daemon does not become reachable
  /// between tests, and the check costs a process spawn.
  static Future<String?> unavailableReason() async {
    if (_unavailable != null) return _unavailable == '' ? null : _unavailable;
    try {
      final docker = DockerCommander(DockerHostLocal());
      await docker.initialize();
      final running = await docker.isDaemonRunning();
      await docker.close();
      _unavailable = running ? '' : 'no Docker daemon is reachable';
    } on Object catch (e) {
      _unavailable = 'Docker is not usable here: $e';
    }
    return _unavailable == '' ? null : _unavailable;
  }

  static String? _unavailable;

  /// Starts a fleet: builds the images if needed, creates a private network,
  /// and issues the Hub's certificate.
  static Future<OmnyFleet> start() async {
    final docker = DockerCommander(DockerHostLocal());
    await docker.initialize();

    if (!_imagesBuilt) {
      await _buildImages(docker);
      _imagesBuilt = true;
    }

    final network = await docker.createNetwork();
    if (network == null) throw StateError('could not create a Docker network');

    // The certificate is issued for the name the containers dial — a real
    // handshake against a real hostname is most of the point of these tests —
    // and CertGenerator always adds localhost/127.0.0.1, which is how the test
    // process reaches the published port. Nothing here runs with TLS
    // verification off.
    final certs = Directory.systemTemp.createTempSync('omnyserver-fleet-certs');
    await CertGenerator.generate(
      outputDir: certs.path,
      hosts: ['$network-$hubHost', hubHost],
      force: true,
    );

    return OmnyFleet._(docker, network, certs, await _freePort());
  }

  /// Builds both runtime images from `test/docker/Dockerfile`.
  static Future<void> _buildImages(DockerCommander docker) async {
    for (final (target, tag) in [
      ('runtime', runtimeImage),
      ('sdk', sdkImage),
    ]) {
      final build = await docker.command('build', [
        '--file',
        'test/docker/Dockerfile',
        '--target',
        target,
        '--tag',
        tag,
        '.',
      ], outputLimit: 4000);
      final exit = await build?.waitExit();
      if (exit != 0) {
        throw StateError(
          'docker build --target $target failed ($exit):\n'
          '${build?.stderr?.asString ?? ''}\n${build?.stdout?.asString ?? ''}',
        );
      }
    }
  }

  /// A free port on the host, for the Hub's published port.
  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// Starts the Hub container and waits until it is serving.
  ///
  /// [dataDir] names a host directory to persist into; without one the Hub is
  /// `--ephemeral`, which is what most cases want.
  Future<DockerContainer> startHub({
    List<String> extraArgs = const [],
    Directory? dataDir,
  }) async {
    final hub = await _run(
      runtimeImage,
      name: hubHost,
      hostname: hubHost,
      ports: ['$publishedPort:$hubPort'],
      volumes: {
        certs.path: '/certs',
        if (dataDir != null) dataDir.path: '/data',
      },
      args: [
        'hub', 'start', //
        '--host', '0.0.0.0',
        '--port', '$hubPort',
        '--cert', '/certs/server.crt',
        '--key', '/certs/server.key',
        '--api-token', apiToken,
        '--grant', 'node-account:$nodeToken:node',
        '--grant', 'alice:$operatorToken:admin',
        if (dataDir != null) ...['--data-dir', '/data'] else '--ephemeral',
        ...extraArgs,
      ],
    );

    // `Hub API:` is the last line of the banner, printed once it is listening.
    await _waitForLog(hub, 'Hub API:', what: 'the Hub');
    _hub = hub;
    return hub;
  }

  /// Starts a node container and waits until it has registered.
  ///
  /// [sdk] picks the image with the Dart SDK on it, so the node has a
  /// capability to find; the default image is bare.
  Future<DockerContainer> startNode({
    required String id,
    Map<String, String> labels = const {},
    String token = nodeToken,
    bool sdk = false,
    bool trustCa = true,
    List<String> extraArgs = const [],
    bool waitForRegistration = true,
  }) async {
    final node = await _run(
      sdk ? sdkImage : runtimeImage,
      name: id,
      hostname: id,
      volumes: {certs.path: '/certs'},
      args: [
        'node', 'start', //
        '--hub', hubUri,
        '--id', id,
        '--principal', 'node-account',
        '--token', token,
        if (trustCa) ...['--ca', '/certs/ca.crt'],
        for (final entry in labels.entries) ...[
          '--label',
          '${entry.key}=${entry.value}',
        ],
        ...extraArgs,
      ],
    );

    if (waitForRegistration) {
      await _waitForLog(node, 'connected to', what: 'node "$id"');
    }
    return node;
  }

  /// Runs the CLI in a throwaway container on the same network — an operator
  /// working from a third machine, rather than from the test process.
  ///
  /// Returns the command's stdout.
  Future<String> runCli(List<String> args) async {
    final name = 'cli-${DateTime.now().microsecondsSinceEpoch}';
    final cli = await _run(
      runtimeImage,
      name: name,
      hostname: name,
      volumes: {certs.path: '/certs'},
      args: [
        ...args,
        '--api', hubApiUri, //
        '--token', operatorToken,
        '--principal', 'alice',
        '--ca', '/certs/ca.crt',
      ],
    );
    await cli.waitExit();
    return cli.stdout?.asString ?? '';
  }

  /// An API client for the Hub, from the test process, over the published port.
  ///
  /// It verifies the Hub's certificate against the dev CA like any other
  /// client would — there is no `--insecure` anywhere in these tests.
  HubApiClient apiClient({String? principal, String? token}) => HubApiClient(
    Uri.parse('https://127.0.0.1:$publishedPort'),
    principal: principal,
    token: token ?? apiToken,
    transport: IoApiTransport(
      securityContext: SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates('${certs.path}/ca.crt'),
    ),
  );

  /// Polls [request] until it satisfies [until], or gives up.
  ///
  /// Containers converge rather than arrive: a node registers, then reports.
  Future<T> eventually<T>(
    Future<T> Function() request,
    bool Function(T value) until, {
    Duration timeout = const Duration(seconds: 30),
    String what = 'the Hub',
  }) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final value = await request();
        if (until(value)) return value;
        lastError = null;
      } on Object catch (e) {
        lastError = e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError(
      'gave up waiting on $what after $timeout'
      '${lastError == null ? '' : ' (last error: $lastError)'}',
    );
  }

  /// Stops a container and waits for it to be gone.
  Future<void> stop(DockerContainer container) async {
    await container.stop(timeout: const Duration(seconds: 5));
    await container.waitExit();
  }

  /// The Hub container, once [startHub] has run.
  DockerContainer get hub =>
      _hub ?? (throw StateError('the Hub has not been started'));

  Future<DockerContainer> _run(
    String image, {
    required String name,
    required String hostname,
    required List<String> args,
    Map<String, String> volumes = const {},
    List<String> ports = const [],
  }) async {
    final container = await docker.run(
      image,
      containerName: '$network-$name',
      hostname: hostname,
      network: network,
      ports: ports.isEmpty ? null : ports,
      volumes: {...volumes},
      imageArgs: args,
      cleanContainer: true,
      outputAsLines: true,
    );
    if (container == null) {
      throw StateError('could not start $name from $image');
    }
    _containers.add(container);
    return container;
  }

  Future<void> _waitForLog(
    DockerContainer container,
    String marker, {
    required String what,
  }) async {
    final found =
        await container.stdout?.waitForDataMatch(
          marker,
          timeout: readyTimeout,
        ) ??
        false;
    if (!found) {
      throw StateError(
        '$what never printed "$marker" within $readyTimeout.\n'
        '--- stdout ---\n${container.stdout?.asString ?? ''}\n'
        '--- stderr ---\n${container.stderr?.asString ?? ''}',
      );
    }
  }

  /// Stops every container and removes the network.
  Future<void> dispose() async {
    for (final container in _containers.reversed) {
      try {
        await container.stop(timeout: const Duration(seconds: 5));
      } on Object {
        // Already gone, or never came up: nothing to do about it here.
      }
    }
    _containers.clear();
    try {
      await docker.removeNetwork(network);
    } on Object {
      // Best effort; a leaked network is cheap and named after this run.
    }
    await docker.close();
    if (certs.existsSync()) certs.deleteSync(recursive: true);
  }
}

/// Skips the running test when Docker is unavailable, returning true.
///
/// Used at the top of every container test, so a checkout without Docker
/// reports skips rather than a wall of failures.
Future<bool> skipWithoutDocker() async {
  final reason = await OmnyFleet.unavailableReason();
  if (reason == null) return false;
  markTestSkipped(reason);
  return true;
}
