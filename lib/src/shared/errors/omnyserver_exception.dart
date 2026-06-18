import 'error_codes.dart';

/// Base type for every expected, classified failure raised by OmnyServer.
///
/// Each exception carries a stable [code] (see [ErrorCodes]) and a
/// human-readable [message]. The hierarchy is `sealed` so callers can
/// exhaustively switch on the failure kind, and so the protocol layer can map
/// between exceptions and `error` control messages without a catch-all.
sealed class OmnyServerException implements Exception {
  /// A stable, machine-readable error code.
  final String code;

  /// A human-readable description of the failure.
  final String message;

  /// Creates an exception with [code] and [message].
  const OmnyServerException(this.code, this.message);

  @override
  String toString() => '$runtimeType($code): $message';
}

/// A frame could not be decoded, or a message violated the protocol.
class ProtocolException extends OmnyServerException {
  /// Creates a protocol exception.
  const ProtocolException(String message, {String? code})
    : super(code ?? ErrorCodes.protocolError, message);
}

/// Authentication failed: credentials missing, malformed or rejected.
class AuthException extends OmnyServerException {
  /// Creates an authentication exception.
  const AuthException(String message) : super(ErrorCodes.authFailed, message);
}

/// The authenticated principal is not permitted to perform the action.
class AuthorizationException extends OmnyServerException {
  /// Creates an authorization exception.
  const AuthorizationException(String message)
    : super(ErrorCodes.notAuthorized, message);
}

/// The requested node is unknown or offline.
class NodeUnavailableException extends OmnyServerException {
  /// Creates a node-unavailable exception with an explicit [code]
  /// ([ErrorCodes.unknownNode] or [ErrorCodes.nodeOffline]).
  const NodeUnavailableException(super.code, super.message);
}

/// A requested resource (formula, preset, node) was not found.
class NotFoundException extends OmnyServerException {
  /// Creates a not-found exception.
  const NotFoundException(String message) : super(ErrorCodes.notFound, message);
}

/// An operation (command, formula, preset) failed during execution.
class OperationException extends OmnyServerException {
  /// Creates an operation-failed exception.
  const OperationException(String message, {String? code})
    : super(code ?? ErrorCodes.operationFailed, message);
}

/// A persistence backend failed to read or write.
class StorageException extends OmnyServerException {
  /// Creates a storage exception.
  const StorageException(String message)
    : super(ErrorCodes.storageError, message);
}

/// The underlying transport failed or closed unexpectedly.
class TransportException extends OmnyServerException {
  /// Creates a transport exception.
  const TransportException(String message)
    : super(ErrorCodes.transportError, message);
}

/// An operation exceeded its deadline.
class OmnyServerTimeoutException extends OmnyServerException {
  /// Creates a timeout exception.
  const OmnyServerTimeoutException(String message)
    : super(ErrorCodes.timeout, message);
}
