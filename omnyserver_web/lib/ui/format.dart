/// Human-readable byte sizes: `1.4 GB`, `812 MB`, `4.0 KB`.
///
/// Decimal units, matching what an operator reads off `df` and a cloud console —
/// not the binary units a purist would prefer.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  // Whole bytes read oddly as "512.0 B"; everything larger wants one decimal.
  final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// [part] of [whole] as a percentage, or `—` when the whole is unknown.
String percent(int part, int whole) {
  if (whole <= 0) return '—';
  return '${(part / whole * 100).toStringAsFixed(0)}%';
}
