import 'dart:async';

import 'package:omnyserver/omnyserver.dart';

/// A pair of in-memory [OmnyConnection]s wired back-to-back, for testing
/// protocol logic without a real socket. Frames sent on one end arrive on the
/// other's [incoming] stream.
class LoopbackPair {
  /// The "client" end.
  final LoopbackConnection a;

  /// The "server" end.
  final LoopbackConnection b;

  LoopbackPair._(this.a, this.b);

  /// Creates a connected loopback pair.
  factory LoopbackPair() {
    final aIn = StreamController<OmnyFrame>.broadcast();
    final bIn = StreamController<OmnyFrame>.broadcast();
    final a = LoopbackConnection._(aIn, bIn);
    final b = LoopbackConnection._(bIn, aIn);
    return LoopbackPair._(a, b);
  }
}

/// One end of a [LoopbackPair].
class LoopbackConnection implements OmnyConnection {
  final StreamController<OmnyFrame> _incoming;
  final StreamController<OmnyFrame> _peer;
  final Completer<void> _done = Completer<void>();
  bool _open = true;

  LoopbackConnection._(this._incoming, this._peer);

  @override
  Stream<OmnyFrame> get incoming => _incoming.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> get done => _done.future;

  @override
  void send(OmnyFrame frame) {
    if (!_open || _peer.isClosed) return;
    _peer.add(frame);
  }

  @override
  void sendMessage(ControlMessage message) => send(ControlFrame(message));

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    if (!_incoming.isClosed) await _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }
}
