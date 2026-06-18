import 'dart:async';

import '../../domain/events/event_bus.dart';
import '../../domain/events/omny_event.dart';

/// Subscribes to an [EventBus] and keeps a bounded, in-memory history of recent
/// events plus per-type counts — the basis for the events API and dashboards.
class EventAggregator {
  /// The maximum number of recent events retained.
  final int capacity;

  final List<OmnyEvent> _recent = [];
  final Map<String, int> _counts = {};
  StreamSubscription<OmnyEvent>? _subscription;

  /// Creates an aggregator retaining up to [capacity] events.
  EventAggregator({this.capacity = 1000});

  /// Begins consuming events from [bus].
  void attach(EventBus bus) {
    _subscription = bus.events.listen(_onEvent);
  }

  void _onEvent(OmnyEvent event) {
    _recent.add(event);
    if (_recent.length > capacity) {
      _recent.removeRange(0, _recent.length - capacity);
    }
    _counts.update(event.type, (v) => v + 1, ifAbsent: () => 1);
  }

  /// The most recent events, newest first, up to [limit].
  List<OmnyEvent> recent({int limit = 100}) =>
      _recent.reversed.take(limit).toList();

  /// The total number of events seen for [type].
  int countOf(String type) => _counts[type] ?? 0;

  /// A snapshot of all per-type counts.
  Map<String, int> get counts => Map.unmodifiable(_counts);

  /// Stops consuming events.
  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
