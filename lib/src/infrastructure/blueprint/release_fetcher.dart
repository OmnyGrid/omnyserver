import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// Where a release bundle comes from, and how to ask for it.
///
/// Three sources, all of them a single GET:
///
/// * `https://…` / `http://…` — fetched as is, with no credentials unless
///   `auth` says otherwise;
/// * `gs://bucket/path/to.zip` — Google Cloud Storage, through its JSON API,
///   authenticated by default with the token the GCE metadata server hands the
///   VM's own service account. A bucket the machine's account can read needs no
///   key on disk at all, which is the point: the credential that cannot leak is
///   the one that was never written down.
///
/// `auth` is `none`, `metadata`, or `bearer-file:/path/to/token`.
class ReleaseFetcher {
  /// The GCS JSON API's base. Overridable so a test can stand in for Google.
  final Uri storageBase;

  /// The metadata server's base. Overridable for the same reason.
  final Uri metadataBase;

  /// Builds the client each fetch uses.
  final HttpClient Function() httpClientFactory;

  /// How long a connection may take to open.
  final Duration connectTimeout;

  /// How long a download may go without receiving a byte.
  ///
  /// Not a limit on the whole download — a large bundle over a slow link is
  /// fine — but a stalled one must end, or it holds the node's apply forever
  /// after the Hub has stopped waiting for it.
  final Duration idleTimeout;

  /// Creates a fetcher.
  ReleaseFetcher({
    Uri? storageBase,
    Uri? metadataBase,
    HttpClient Function()? httpClientFactory,
    this.connectTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(minutes: 2),
  }) : storageBase =
           storageBase ?? Uri.parse('https://storage.googleapis.com/'),
       metadataBase =
           metadataBase ?? Uri.parse('http://metadata.google.internal/'),
       httpClientFactory = httpClientFactory ?? HttpClient.new;

  /// The URL a `gs://` location is actually fetched from; anything else as is.
  Uri resolve(String location) {
    final uri = Uri.parse(location);
    if (uri.scheme == 'http' || uri.scheme == 'https') return uri;
    if (uri.scheme != 'gs') {
      throw ArgumentError(
        'unsupported release url "$location" — use https://, http:// or gs://',
      );
    }
    final bucket = uri.host;
    final object = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
    if (bucket.isEmpty || object.isEmpty) {
      throw ArgumentError('"$location" names no bucket and object');
    }
    // The object name is one path segment, slashes and all: the JSON API wants
    // `o/nfeflash_api%2Fbundle.zip`, not `o/nfeflash_api/bundle.zip`.
    return storageBase.resolve(
      'download/storage/v1/b/${Uri.encodeComponent(bucket)}/o/'
      '${Uri.encodeComponent(object)}?alt=media',
    );
  }

  /// The `auth` a [location] gets when the resource names none.
  static String defaultAuth(String location) =>
      Uri.parse(location).scheme == 'gs' ? 'metadata' : 'none';

  /// Streams [location] into [destination], returning its SHA-256 (lowercase
  /// hex) as computed over the bytes written.
  ///
  /// Never holds the bundle in memory: a release is tens of megabytes and the
  /// node is somebody's production server. The hash is taken on the way through
  /// rather than by reading the file back, so what is verified is exactly what
  /// was written.
  Future<String> fetch(
    String location,
    File destination, {
    String? auth,
    void Function(String line)? log,
  }) async {
    final uri = resolve(location);
    final mode = auth ?? defaultAuth(location);
    final token = await _token(mode);

    final client = httpClientFactory()..connectionTimeout = connectTimeout;
    try {
      final request = await client.getUrl(uri);
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        final body = await _shortBody(response);
        throw HttpException(
          'GET $location: HTTP ${response.statusCode}'
          '${body.isEmpty ? '' : ' — $body'}',
          uri: uri,
        );
      }

      final hasher = Sha256().toSync().newHashSink();
      final sink = destination.openWrite();
      var bytes = 0;
      try {
        await for (final chunk in response.timeout(idleTimeout)) {
          hasher.add(chunk);
          sink.add(chunk);
          bytes += chunk.length;
        }
      } on TimeoutException {
        throw HttpException(
          'GET $location stalled: nothing received for '
          '${idleTimeout.inSeconds}s after ${_size(bytes)}',
          uri: uri,
        );
      } finally {
        await sink.close();
      }
      hasher.close();
      final digest = await hasher.hash();
      log?.call('downloaded $location (${_size(bytes)})');
      return _hex(digest.bytes);
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _token(String mode) async {
    if (mode == 'none') return null;
    if (mode == 'metadata') return _metadataToken();
    if (mode.startsWith('bearer-file:')) {
      final path = mode.substring('bearer-file:'.length);
      final file = File(path);
      if (!file.existsSync()) {
        throw ArgumentError('auth $mode: no such file');
      }
      final token = file.readAsStringSync().trim();
      if (token.isEmpty) throw ArgumentError('auth $mode: the file is empty');
      return token;
    }
    throw ArgumentError(
      'unknown auth "$mode" — use none, metadata or bearer-file:/path',
    );
  }

  /// The access token of the VM's default service account.
  Future<String> _metadataToken() async {
    final uri = metadataBase.resolve(
      'computeMetadata/v1/instance/service-accounts/default/token',
    );
    final client = httpClientFactory()..connectionTimeout = connectTimeout;
    try {
      final request = await client.getUrl(uri);
      request.headers.set('Metadata-Flavor', 'Google');
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'the metadata server refused a token: HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      final json = jsonDecode(body);
      final token = json is Map ? json['access_token'] : null;
      if (token is! String || token.isEmpty) {
        throw const FormatException('the metadata server sent no access_token');
      }
      return token;
    } on SocketException catch (e) {
      // Said in the terms of what was asked for: on a laptop, "Failed host
      // lookup: metadata.google.internal" reads like a DNS fault, when the
      // truth is that this machine is not a GCE VM.
      throw HttpException(
        'auth metadata: no metadata server reachable (${e.message}) — this '
        'only works on a Google Cloud VM; use auth: bearer-file:… elsewhere',
        uri: uri,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _shortBody(HttpClientResponse response) async {
    try {
      final text = await utf8.decodeStream(response);
      final line = text.trim().split('\n').first;
      return line.length > 200 ? '${line.substring(0, 200)}…' : line;
    } on Object {
      return '';
    }
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  static String _hex(List<int> bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
}
