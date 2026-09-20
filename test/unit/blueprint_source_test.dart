@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:test/test.dart';

/// Turning an authored document into a blueprint.
///
/// The half of the parser that is free of `dart:io`, and therefore the half the
/// dashboard's editor runs. That matters for the refusals especially: these
/// messages used to be read off a terminal beside the file that caused them,
/// and are now shown in a browser to somebody who has just pressed Save. Each
/// one has to name the document and say what was wrong with it.
void main() {
  group('YAML', () {
    test('a document parses, and keeps the text it was written as', () {
      const source =
          '# Everything a build host needs.\n'
          'blueprint: builder\n'
          'name: Build host\n'
          'includes: [dev-tools]\n'
          'resources:\n'
          '  - { type: formula, name: nmap, ensure: installed }\n';

      final blueprint = parseBlueprint(source, BlueprintFormat.yaml);

      expect(blueprint.id.value, 'builder');
      expect(blueprint.name, 'Build host');
      expect(blueprint.includes.single.value, 'dev-tools');
      expect(blueprint.resources.single.id.toString(), 'formula:nmap');
      expect(blueprint.resources.single.ensure, Ensure.installed);
      // The comment survives, which is the whole reason the source travels
      // with the parsed form.
      expect(blueprint.source!.text, source);
      expect(blueprint.source!.format, BlueprintFormat.yaml);
    });

    test('nested maps and lists arrive as plain JSON types', () {
      // `loadYaml` answers in `YamlMap`/`YamlList`, which are Maps and Lists but
      // not the ones `fromJson` expects. Converting once at the boundary is why
      // no `fromJson` anywhere has to know YAML exists.
      final blueprint = parseBlueprint(
        'blueprint: b\n'
        'vars: { registry: ghcr.io }\n'
        'resources:\n'
        '  - type: formula\n'
        '    name: docker\n'
        '    params: { version: "24.0" }\n'
        '    requires: [formula:dart]\n',
        BlueprintFormat.yaml,
      );

      expect(blueprint.vars, {'registry': 'ghcr.io'});
      expect(blueprint.resources.single.params, {'version': '24.0'});
      expect(
        blueprint.resources.single.requires.single.toString(),
        'formula:dart',
      );
    });

    test('a syntax error names the document and what was wrong', () {
      expect(
        () => parseBlueprint(
          'blueprint: [unclosed',
          BlueprintFormat.yaml,
          origin: 'the editor',
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('the editor'), contains('not valid YAML')),
          ),
        ),
      );
    });

    test('a list where a blueprint should be is refused, not misread', () {
      // Valid YAML, and not a blueprint. Without this it reaches `fromJson` as
      // a cast failure, which says nothing a person can act on.
      expect(
        () => parseBlueprint(
          '- one\n- two\n',
          BlueprintFormat.yaml,
          origin: 'the editor',
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('the editor'), contains('not a list or a scalar')),
          ),
        ),
      );
    });

    test('a bare scalar is refused the same way', () {
      expect(
        () => parseBlueprint('just a string\n', BlueprintFormat.yaml),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('JSON', () {
    test('a document parses, and stays JSON', () {
      const source =
          '{"blueprint": "builder", "name": "Build host", '
          '"resources": [{"type": "formula", "name": "nmap"}]}';

      final blueprint = parseBlueprint(source, BlueprintFormat.json);

      expect(blueprint.id.value, 'builder');
      expect(blueprint.resources.single.id.name, 'nmap');
      expect(blueprint.source!.format, BlueprintFormat.json);
      expect(blueprint.source!.text, source);
    });

    test('a syntax error names the document and what was wrong', () {
      expect(
        () => parseBlueprint(
          '{"blueprint": ',
          BlueprintFormat.json,
          origin: 'the editor',
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('the editor'), contains('not valid JSON')),
          ),
        ),
      );
    });

    test('a list where a blueprint should be says what it got instead', () {
      expect(
        () => parseBlueprint('[1, 2, 3]', BlueprintFormat.json),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('should hold a blueprint object'),
          ),
        ),
      );
    });
  });

  group('the format is told, never sniffed', () {
    test('the same bytes parse as either, and keep the format they were '
        'read as', () {
      // JSON is valid YAML, which is exactly why sniffing would be wrong: the
      // format a document is *saved* as would change the first time somebody
      // added a comment.
      const source = '{"blueprint": "b", "name": "B"}';

      expect(
        parseBlueprint(source, BlueprintFormat.yaml).source!.format,
        BlueprintFormat.yaml,
      );
      expect(
        parseBlueprint(source, BlueprintFormat.json).source!.format,
        BlueprintFormat.json,
      );
    });

    test('an extension picks the format, and anything unfamiliar is JSON', () {
      // JSON is the wire's own format, and the right assumption for a file with
      // no extension at all.
      expect(blueprintFormatOf('builder.yaml'), BlueprintFormat.yaml);
      expect(blueprintFormatOf('builder.yml'), BlueprintFormat.yaml);
      expect(blueprintFormatOf('BUILDER.YAML'), BlueprintFormat.yaml);
      expect(blueprintFormatOf('builder.json'), BlueprintFormat.json);
      expect(blueprintFormatOf('builder'), BlueprintFormat.json);
      expect(blueprintFormatOf('/etc/omny/builder.txt'), BlueprintFormat.json);
      // A dot in a directory name is not an extension on the file.
      expect(blueprintFormatOf('v1.2/builder.yaml'), BlueprintFormat.yaml);
    });
  });

  test('a document missing its id is refused', () {
    // `blueprint:` or `id:` — one of them has to be there, because it is how
    // every node refers to the thing.
    expect(
      () => parseBlueprint('name: nameless\n', BlueprintFormat.yaml),
      throwsA(isA<OmnyServerException>()),
    );
  });
}
