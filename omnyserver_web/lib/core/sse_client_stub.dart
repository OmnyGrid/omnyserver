/// The VM has no `fetch`, and no browser to stream into.
///
/// This exists so the service layer — which is otherwise pure — stays loadable
/// on the VM and can be unit-tested with `dart test` rather than needing headless
/// Chrome. A VM caller (a test, the CLI) that wants a live event stream reads the
/// SSE response off an `HttpClient` directly, as `omnyserver events --follow`
/// does.
Stream<String> sseStream(Uri uri, {Map<String, String> headers = const {}}) =>
    throw UnsupportedError(
      'sseStream() needs the browser\'s fetch; on the VM, read '
      '/api/v1/events/stream with an HttpClient instead.',
    );
