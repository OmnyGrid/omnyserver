import 'resource.dart';

/// The resource types OmnyServer ships a provider for, beyond `formula`, and
/// the `ensure` values each one accepts.
///
/// One list, read by both sides. The Hub checks a blueprint against it at
/// `blueprint save`, so a release declared `running` is refused while the
/// author is still looking at it. The node's providers take their
/// `supportedEnsure` from it, so the two cannot drift apart.
enum BuiltInProvider {
  /// A versioned application bundle: present or absent, never running.
  release({Ensure.present, Ensure.installed, Ensure.absent}),

  /// A native OS service.
  service({
    Ensure.present,
    Ensure.installed,
    Ensure.running,
    Ensure.stopped,
    Ensure.absent,
  });

  const BuiltInProvider(this.supportedEnsure);

  /// The `ensure` values a resource of this type may declare.
  final Set<Ensure> supportedEnsure;

  /// The resource type, as written in a blueprint: `release`, `service`.
  String get type => name;

  /// The built-in provider for [type], or `null` for any other type —
  /// `formula`, or one a site registered itself.
  static BuiltInProvider? byType(String type) {
    for (final p in values) {
      if (p.type == type) return p;
    }
    return null;
  }
}
