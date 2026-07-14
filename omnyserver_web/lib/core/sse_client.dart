/// Reads a Server-Sent Events stream, yielding each event's `data` payload.
///
/// Browser-only in practice: the implementation is selected at compile time so
/// that importing it does not drag `package:web` into a VM build, which would
/// make the service layer — and every consumer's unit tests — unloadable on the
/// Dart VM.
library;

export 'sse_client_stub.dart'
    if (dart.library.js_interop) 'sse_client_web.dart';
