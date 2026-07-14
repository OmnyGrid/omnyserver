import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

/// A small line chart of one metric over time.
///
/// Inline SVG, drawn by hand. A charting library would be several hundred
/// kilobytes of JavaScript to draw a polyline, and this is a polyline — the
/// point of the panel is "is it climbing", not a data-exploration surface.
///
/// [values] run oldest-to-newest. [max] fixes the vertical scale (100 for a
/// percentage) so two charts side by side are comparable, and so a flat 5% line
/// looks flat instead of being stretched to fill the box.
web.HTMLElement sparkline(
  List<double> values, {
  required String label,
  required String caption,
  double max = 100,
  double width = 320,
  double height = 48,
}) {
  final host = el('div', classes: 'stack sparkline');
  host.appendChild(
    el(
      'div',
      classes: 'row',
      children: [
        el('div', classes: 'muted grow', text: label),
        el('div', classes: 'mono', text: caption),
      ],
    ),
  );

  if (values.length < 2) {
    host.appendChild(
      el('div', classes: 'hint', text: 'Not enough history to plot yet.'),
    );
    return host;
  }

  final step = width / (values.length - 1);
  final points = <String>[];
  for (var i = 0; i < values.length; i++) {
    final x = i * step;
    // SVG's y grows downward, so a high value has to become a low y.
    final clamped = values[i].clamp(0, max);
    final y = height - (clamped / max) * height;
    points.add('${x.toStringAsFixed(1)},${y.toStringAsFixed(1)}');
  }

  // createElementNS, not createElement: SVG lives in its own XML namespace, and
  // an HTML element that merely happens to be called <svg> renders nothing at
  // all. (Nor innerHTML — no reason to open that door to draw a line.)
  const ns = 'http://www.w3.org/2000/svg';
  final svg = web.document.createElementNS(ns, 'svg');
  svg
    ..setAttribute('viewBox', '0 0 $width $height')
    ..setAttribute('width', '100%')
    ..setAttribute('height', '$height')
    // The chart stretches to its container; without this the aspect ratio would
    // be preserved and the line would not span the card.
    ..setAttribute('preserveAspectRatio', 'none')
    ..setAttribute('class', 'spark');

  final line = web.document.createElementNS(ns, 'polyline');
  line
    ..setAttribute('points', points.join(' '))
    ..setAttribute('fill', 'none')
    // currentColor, so the line follows the theme rather than pinning a colour
    // that would vanish against a dark background.
    ..setAttribute('stroke', 'currentColor')
    ..setAttribute('stroke-width', '1.5')
    // The viewBox is stretched, which would stretch the stroke with it.
    ..setAttribute('vector-effect', 'non-scaling-stroke');

  svg.appendChild(line);
  host.appendChild(svg);
  return host;
}
