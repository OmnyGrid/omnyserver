@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_client_web.dart' show BlueprintFormat;
import 'package:omnyserver_web/ui/code_tokens.dart';
import 'package:test/test.dart';

/// The editor paints these tokens on a layer underneath the caret, so the one
/// property that cannot bend is that they reproduce the document exactly. A
/// dropped or duplicated character does not show up as a missing colour — it
/// shifts every line after it, and the author watches their own text slide out
/// from under the highlighting as they type.
void main() {
  /// Every token's text, concatenated.
  String rebuild(String source, BlueprintFormat format) =>
      tokenizeCode(source, format).map((t) => t.text).join();

  /// The classes covering [needle], to assert what a run was called.
  Set<String?> classesOf(
    String source,
    BlueprintFormat format,
    String needle,
  ) => {
    for (final token in tokenizeCode(source, format))
      if (token.text.contains(needle)) token.className,
  };

  group('whatever goes in comes back out', () {
    const documents = {
      'a blueprint':
          '# What a web server should be.\n'
          'blueprint: web-server\n'
          'name: Web server\n'
          'platforms: [linux]\n'
          'includes: [base-tools]\n'
          'resources:\n'
          '  - { type: formula, name: nmap, ensure: installed }\n',
      'a preset':
          '{\n'
          '  "id": "base-tools",\n'
          '  "name": "Base tools",\n'
          '  "steps": [\n'
          '    { "formula": "git", "action": "install" }\n'
          '  ]\n'
          '}\n',
      'empty': '',
      'one space': ' ',
      'newlines only': '\n\n\n',
      // Everything below is something the editor sees while it is being typed,
      // and is invalid at the moment it is seen.
      'an unterminated string': 'name: "Web ser',
      'an unterminated json string': '{"id": "base-too',
      'a lone colon': ':',
      'a lone brace': '{',
      'trailing backslash': r'{"a": "b\',
      'a colon inside a scalar': 'hub: https://hub.example.com:8443\n',
      'a hash inside a scalar': 'name: web-server#1\n',
      'a quoted key': '"blueprint": web-server\n',
      'flow nested in flow': 'a: { b: [1, 2, {c: d}], e: f }\n',
      'a block scalar':
          'params:\n  script: |\n    set -e\n    apt-get update\n',
      'tabs': '\ta:\tb\n',
      'unicode': 'name: café — ✓\n',
      'crlf': 'a: 1\r\nb: 2\r\n',
    };

    for (final entry in documents.entries) {
      test('${entry.key}, as YAML', () {
        expect(rebuild(entry.value, BlueprintFormat.yaml), entry.value);
      });
      test('${entry.key}, as JSON', () {
        expect(rebuild(entry.value, BlueprintFormat.json), entry.value);
      });
    }
  });

  group('YAML', () {
    test('a mapping key is a key and its value is not', () {
      const source = 'blueprint: web-server\n';
      expect(classesOf(source, BlueprintFormat.yaml, 'blueprint'), {tokenKey});
      expect(classesOf(source, BlueprintFormat.yaml, 'web-server'), {
        tokenString,
      });
    });

    test('keys inside a flow mapping are keys too', () {
      // The blueprints in `example/` are written this way, and a scanner that
      // only looked at the start of a line would paint the whole line as one
      // scalar.
      const source = '  - { type: formula, name: nmap, ensure: installed }\n';
      expect(classesOf(source, BlueprintFormat.yaml, 'type'), {tokenKey});
      expect(classesOf(source, BlueprintFormat.yaml, 'ensure'), {tokenKey});
      expect(classesOf(source, BlueprintFormat.yaml, 'formula'), {tokenString});
    });

    test('a comment runs to the end of the line and no further', () {
      const source = '# What a web server should be.\nname: web\n';
      expect(classesOf(source, BlueprintFormat.yaml, 'What a web'), {
        tokenComment,
      });
      expect(classesOf(source, BlueprintFormat.yaml, 'name'), {tokenKey});
    });

    test('a colon inside a URL does not make a key of what precedes it', () {
      const source = 'hub: https://hub.example.com:8443\n';
      // The whole URL is one scalar — the `:` before the port separates
      // nothing, because a key separator is a colon followed by a space.
      expect(classesOf(source, BlueprintFormat.yaml, 'https'), {tokenString});
      // `hub` appears twice over, so this is the first token rather than a
      // search: the key, and only the key.
      final tokens = tokenizeCode(source, BlueprintFormat.yaml);
      expect(tokens.first.text, 'hub');
      expect(tokens.first.className, tokenKey);
    });

    test('a comma in prose does not end the scalar', () {
      // In block context a comma is an ordinary character. Every blueprint in
      // `example/` has a `description` with one in it, and chopping the
      // sentence there paints half of it as structure.
      const source =
          'description: A host that serves traffic, and can be debugged.\n';
      final value = tokenizeCode(
        source,
        BlueprintFormat.yaml,
      ).where((t) => t.className == tokenString).map((t) => t.text);
      expect(value, ['A host that serves traffic, and can be debugged.']);
    });

    test('a comma inside a flow mapping still separates', () {
      const source = '- { type: formula, name: nmap }\n';
      expect(classesOf(source, BlueprintFormat.yaml, 'name'), {tokenKey});
    });

    test('a hash mid-token is not a comment', () {
      const source = 'name: web-server#1\n';
      expect(
        tokenizeCode(
          source,
          BlueprintFormat.yaml,
        ).where((t) => t.className == tokenComment),
        isEmpty,
      );
    });

    test('numbers and booleans are told apart from plain scalars', () {
      const source = 'port: 8443\ntls: true\nname: nginx\n';
      expect(classesOf(source, BlueprintFormat.yaml, '8443'), {tokenNumber});
      expect(classesOf(source, BlueprintFormat.yaml, 'true'), {tokenLiteral});
      expect(classesOf(source, BlueprintFormat.yaml, 'nginx'), {tokenString});
    });

    test('a block scalar is text, however much it looks like YAML', () {
      // The case this exists for: a shell script in a `params` value, full of
      // colons and dashes, which would otherwise paint as a wall of keys.
      const source =
          'params:\n'
          '  script: |\n'
          '    set -e\n'
          '    apt-get install: nginx\n'
          'ensure: installed\n';
      expect(classesOf(source, BlueprintFormat.yaml, 'apt-get install'), {
        tokenString,
      });
      // …and the document resumes at the first line that dedents.
      expect(classesOf(source, BlueprintFormat.yaml, 'ensure'), {tokenKey});
    });

    test('a list marker is structure, not part of the value', () {
      const source = '- nmap\n';
      final tokens = tokenizeCode(source, BlueprintFormat.yaml);
      expect(tokens.first.className, tokenPunct);
      expect(tokens.first.text, '-');
      expect(classesOf(source, BlueprintFormat.yaml, 'nmap'), {tokenString});
    });
  });

  group('JSON', () {
    test('a key is told from a string value by the colon after it', () {
      const source = '{"id": "base-tools"}';
      expect(classesOf(source, BlueprintFormat.json, '"id"'), {tokenKey});
      expect(classesOf(source, BlueprintFormat.json, '"base-tools"'), {
        tokenString,
      });
    });

    test('numbers and literals are their own', () {
      const source = '{"port": 8443, "tls": true, "note": null}';
      expect(classesOf(source, BlueprintFormat.json, '8443'), {tokenNumber});
      expect(classesOf(source, BlueprintFormat.json, 'true'), {tokenLiteral});
      expect(classesOf(source, BlueprintFormat.json, 'null'), {tokenLiteral});
    });

    test('an escaped quote does not end the string', () {
      const source = r'{"a": "b\"c", "d": 1}';
      expect(classesOf(source, BlueprintFormat.json, r'b\"c'), {tokenString});
      expect(classesOf(source, BlueprintFormat.json, '"d"'), {tokenKey});
    });

    test('a word inside an identifier is not a literal', () {
      const source = '{"nullable": 1}';
      expect(classesOf(source, BlueprintFormat.json, '"nullable"'), {tokenKey});
    });
  });

  group('the output is worth rendering', () {
    test('neighbouring runs of one class are merged', () {
      // Otherwise every character of indentation is its own DOM node, and a
      // document of any size costs thousands of them.
      final tokens = tokenizeCode('a: 1\nb: 2\n', BlueprintFormat.yaml);
      for (var i = 1; i < tokens.length; i++) {
        expect(
          tokens[i].className,
          isNot(tokens[i - 1].className),
          reason: 'token $i repeats its neighbour\'s class',
        );
      }
    });

    test('no token is empty', () {
      final tokens = tokenizeCode(
        '# c\na: { b: [1], c: "d" }\n',
        BlueprintFormat.yaml,
      );
      expect(tokens.map((t) => t.text), everyElement(isNotEmpty));
    });
  });
}
