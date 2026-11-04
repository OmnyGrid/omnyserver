import 'dart:async';
import 'dart:io';

/// Decides whether a service that has just been started is actually working.
///
/// "The unit is active" is not that: systemd reports a process as running for
/// the instant between `exec` and the crash, and a service that is up but
/// answering 500s is running by every measure the OS has. A health check asks
/// the service itself.
abstract interface class HealthProbe {
  /// `null` when healthy, otherwise why not — in a sentence for an operator.
  Future<String?> check(HealthCheck check);
}

/// One way of asking a service whether it is healthy.
class HealthCheck {
  /// A URL whose GET must answer 2xx.
  final Uri? url;

  /// A shell command that must exit 0.
  final String? command;

  /// Creates a health check.
  const HealthCheck({this.url, this.command});

  /// Whether there is anything to check.
  bool get isEmpty => url == null && command == null;

  @override
  String toString() => url != null ? 'GET $url' : 'command `$command`';
}

/// The real probe: an HTTP GET, or a command through the platform shell.
class DefaultHealthProbe implements HealthProbe {
  /// How long one attempt may take.
  final Duration attemptTimeout;

  /// Creates the probe.
  const DefaultHealthProbe({this.attemptTimeout = const Duration(seconds: 5)});

  @override
  Future<String?> check(HealthCheck check) async {
    if (check.url != null) return _http(check.url!);
    if (check.command != null) return _command(check.command!);
    return null;
  }

  Future<String?> _http(Uri url) async {
    final client = HttpClient()..connectionTimeout = attemptTimeout;
    try {
      final request = await client.getUrl(url).timeout(attemptTimeout);
      final response = await request.close().timeout(attemptTimeout);
      await response.drain<void>();
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      return ok ? null : 'GET $url answered HTTP ${response.statusCode}';
    } on TimeoutException {
      return 'GET $url did not answer within ${attemptTimeout.inSeconds}s';
    } on Object catch (e) {
      return 'GET $url failed: $e';
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _command(String command) async {
    final shell = Platform.isWindows ? 'cmd' : '/bin/sh';
    final args = Platform.isWindows ? ['/c', command] : ['-c', command];
    try {
      final result = await Process.run(shell, args).timeout(attemptTimeout * 6);
      if (result.exitCode == 0) return null;
      final err = '${result.stderr}'.trim();
      return '`$command` exited ${result.exitCode}${err.isEmpty ? '' : ': $err'}';
    } on TimeoutException {
      return '`$command` did not finish';
    }
  }
}
