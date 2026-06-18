/// Stable, machine-readable error codes carried in `error` control messages
/// and surfaced on [OmnyServerException]s.
///
/// Codes are part of the wire contract: clients may switch on them, so values
/// must remain stable across releases.
class ErrorCodes {
  const ErrorCodes._();

  // Protocol / framing.
  /// A frame could not be decoded or violated the protocol.
  static const String protocolError = 'protocol_error';

  /// A binary data frame had a malformed or oversized header.
  static const String malformedFrame = 'malformed_frame';

  /// The peer advertised an incompatible protocol version.
  static const String versionMismatch = 'version_mismatch';

  // Authentication / authorization.
  /// Credentials were missing, malformed or rejected.
  static const String authFailed = 'auth_failed';

  /// The authenticated principal is not permitted to perform the action.
  static const String notAuthorized = 'not_authorized';

  /// An operation was attempted before authentication completed.
  static const String notAuthenticated = 'not_authenticated';

  // Nodes / operations.
  /// The requested node is not registered with the Hub.
  static const String unknownNode = 'unknown_node';

  /// The requested node is currently offline.
  static const String nodeOffline = 'node_offline';

  /// The requested command or operation parameters were invalid.
  static const String badRequest = 'bad_request';

  /// A requested formula, preset or other resource was not found.
  static const String notFound = 'not_found';

  /// An operation (formula/preset/command) failed on the node.
  static const String operationFailed = 'operation_failed';

  // Transport / lifecycle.
  /// The underlying transport failed or closed unexpectedly.
  static const String transportError = 'transport_error';

  /// An operation exceeded its deadline.
  static const String timeout = 'timeout';

  /// A persistence backend failed.
  static const String storageError = 'storage_error';

  /// An unexpected, unclassified failure.
  static const String internalError = 'internal_error';
}
