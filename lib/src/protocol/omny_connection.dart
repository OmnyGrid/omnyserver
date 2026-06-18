import 'control_message.dart';
import 'omny_frame.dart';

/// A transport-agnostic, full-duplex frame channel between two OmnyServer
/// peers.
///
/// This is the **port** the rest of the system depends on; the initial adapter
/// is WebSocket-on-TLS (`WebSocketConnection`), but gRPC / QUIC / a message bus
/// could implement the same contract without touching the runtimes.
abstract class OmnyConnection {
  /// The stream of inbound frames. Malformed frames are dropped (fail-open);
  /// protocol violations are enforced by the runtimes (fail-closed).
  Stream<OmnyFrame> get incoming;

  /// Whether the connection is currently open.
  bool get isOpen;

  /// Completes when the connection is fully closed.
  Future<void> get done;

  /// Sends [frame] to the peer.
  void send(OmnyFrame frame);

  /// Convenience: sends a [ControlMessage] wrapped in a [ControlFrame].
  void sendMessage(ControlMessage message) => send(ControlFrame(message));

  /// Closes the connection.
  Future<void> close([int? code, String? reason]);
}
