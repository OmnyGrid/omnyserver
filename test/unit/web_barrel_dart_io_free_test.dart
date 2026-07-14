@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Guards that the web barrel (`lib/omnyserver_client_web.dart`) and everything
/// it transitively imports or exports stays `dart:io`-free, so a browser app can
/// actually compile it.
///
/// This is not a style rule. `dart2js` **silently emits no output** for an
/// entrypoint whose graph reaches an unsupported SDK library: the build appears
/// to succeed and the app is simply blank. The equivalent test in `omnyshell`
/// exists because that is exactly what happened there (1.43.1), and it stayed
/// invisible until someone opened the page. A grep would not do — the offending
/// import is usually three or four hops away, through an entity that innocently
/// needed one helper.
///
/// Conditional imports (`import 'x_io.dart' if (dart.library.js_interop)
/// 'x_web.dart'`) are resolved to the branch dart2js would take for the web, so
/// a legitimately platform-split library (`platform_info`, `api_transport`) is
/// not flagged.
void main() {
  test('omnyserver_client_web.dart transitively imports no dart:io', () {
    expect(
      Directory('lib').existsSync(),
      isTrue,
      reason: 'test must run from the package root',
    );

    final barrel = File('lib/omnyserver_client_web.dart');
    expect(barrel.existsSync(), isTrue, reason: 'web barrel not found');

    // Matches a whole import/export directive up to its terminating `;`.
    final directive = RegExp(r'^(?:import|export)\b[^;]*;', multiLine: true);
    final quoted = RegExp('''['"]([^'"]+)['"]''');
    final conditional = RegExp('''if\\s*\\(([^)]*)\\)\\s*['"]([^'"]+)['"]''');

    final offenders = <String>[];
    final visited = <String>{};

    /// Whether `dart.library.X` holds for a web/JS target.
    bool condTrueForWeb(String cond) {
      final neg = cond.trimLeft().startsWith('!');
      final webLib = RegExp(
        r'dart\.library\.(js|js_interop|js_util|html|wasm)',
      );
      final bool base;
      if (cond.contains('dart.library.io')) {
        base = false; // dart:io is unavailable on the web
      } else if (webLib.hasMatch(cond)) {
        base = true;
      } else {
        base = false; // unknown condition → the default branch is taken
      }
      return neg ? !base : base;
    }

    /// The URI dart2js would resolve this directive to for a web target.
    String? webUriOf(String body) {
      final defaultUri = quoted.firstMatch(body)?.group(1);
      for (final m in conditional.allMatches(body)) {
        if (condTrueForWeb(m.group(1)!)) return m.group(2);
      }
      return defaultUri;
    }

    void walk(String absPath, List<String> chain) {
      final norm = p.normalize(absPath);
      if (!visited.add(norm)) return;

      final file = File(norm);
      if (!file.existsSync()) return; // generated/part-only — skip defensively

      final here = [...chain, p.relative(norm)];
      for (final d in directive.allMatches(file.readAsStringSync())) {
        final uri = webUriOf(d.group(0)!);
        if (uri == null) continue;

        if (uri == 'dart:io') {
          offenders.add('${here.join(' -> ')} -> dart:io');
          continue;
        }
        if (uri.startsWith('dart:')) continue;

        final String target;
        if (uri.startsWith('package:omnyserver/')) {
          target = p.join('lib', uri.substring('package:omnyserver/'.length));
        } else if (uri.startsWith('package:')) {
          continue; // third-party — not part of our lib graph
        } else {
          target = p.join(p.dirname(norm), uri); // relative
        }
        walk(target, here);
      }
    }

    walk(barrel.path, const []);

    expect(
      offenders,
      isEmpty,
      reason:
          'the web barrel must stay dart:io-free or dart2js emits nothing at '
          'all; offending import chain(s):\n  ${offenders.join('\n  ')}',
    );
  });
}
