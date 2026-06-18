import 'dart:async';

import 'omny_event.dart';

/// A publish/subscribe bus for [OmnyEvent]s.
///
/// The Hub publishes lifecycle and operational events here; subscribers (the
/// event aggregator, metrics, future websocket/SSE streamers) consume them.
abstract class EventBus {
  /// The stream of all published events.
  Stream<OmnyEvent> get events;

  /// Publishes [event] to all subscribers.
  void publish(OmnyEvent event);

  /// Releases resources held by the bus.
  Future<void> close();
}

/// The default in-process [EventBus], backed by a broadcast stream.
class BroadcastEventBus implements EventBus {
  final StreamController<OmnyEvent> _controller =
      StreamController<OmnyEvent>.broadcast();

  /// Creates a broadcast event bus.
  BroadcastEventBus();

  @override
  Stream<OmnyEvent> get events => _controller.stream;

  @override
  void publish(OmnyEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  @override
  Future<void> close() => _controller.close();
}
