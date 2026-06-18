/// A minimal metrics registry that renders Prometheus text exposition.
///
/// Supports monotonically-increasing counters and point-in-time gauges, with
/// optional dynamic gauge providers (evaluated at scrape time). The output is
/// the OpenMetrics/Prometheus text format consumable by Prometheus and
/// OpenTelemetry collectors.
class MetricsRegistry {
  final Map<String, _Metric> _counters = {};
  final Map<String, _Metric> _gauges = {};
  final Map<String, double Function()> _gaugeProviders = {};
  final Map<String, String> _help = {};

  /// Registers help text for a metric [name].
  void describe(String name, String help) => _help[name] = help;

  /// Increments the counter [name] by [amount].
  void incrementCounter(String name, {double amount = 1}) {
    _counters.putIfAbsent(name, () => _Metric()).value += amount;
  }

  /// Sets the gauge [name] to [value].
  void setGauge(String name, double value) {
    _gauges.putIfAbsent(name, () => _Metric()).value = value;
  }

  /// Registers a dynamic gauge [name] evaluated at scrape time.
  void registerGauge(String name, double Function() provider) {
    _gaugeProviders[name] = provider;
  }

  /// The current value of counter [name].
  double counter(String name) => _counters[name]?.value ?? 0;

  /// Renders the Prometheus text exposition for all metrics.
  String render() {
    final buffer = StringBuffer();
    void emit(String name, String type, double value) {
      final help = _help[name];
      if (help != null) buffer.writeln('# HELP $name $help');
      buffer.writeln('# TYPE $name $type');
      buffer.writeln('$name $value');
    }

    for (final entry in _counters.entries) {
      emit(entry.key, 'counter', entry.value.value);
    }
    for (final entry in _gauges.entries) {
      emit(entry.key, 'gauge', entry.value.value);
    }
    for (final entry in _gaugeProviders.entries) {
      emit(entry.key, 'gauge', entry.value());
    }
    return buffer.toString();
  }
}

class _Metric {
  double value = 0;
}
