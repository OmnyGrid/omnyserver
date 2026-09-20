@TestOn('vm')
library;

import 'package:omnyserver/omnyserver_hub.dart';
import 'package:test/test.dart';

/// Resolution: turning a blueprint and the presets it borrows into the flat,
/// ordered list a node is sent.
///
/// This is the piece most worth pinning down, because everything downstream
/// trusts it. The node does not know what a preset is, what a variable was, or
/// which document a resource came from — it acts on what resolution produced,
/// so a mistake here is a mistake applied to real machines with no second check.
void main() {
  const resolver = BlueprintResolver();

  Preset preset(String id, List<PresetStep> steps) =>
      Preset(id: PresetId(id), name: id, steps: steps);

  PresetStep step(
    String formula, {
    FormulaAction action = FormulaAction.install,
    String? version,
  }) =>
      PresetStep(formula: FormulaId(formula), action: action, version: version);

  Blueprint blueprint({
    String id = 'web',
    List<String> includes = const [],
    Map<String, String> vars = const {},
    List<Resource> resources = const [],
  }) => Blueprint(
    id: BlueprintId(id),
    name: id,
    includes: [for (final i in includes) PresetId(i)],
    vars: vars,
    resources: resources,
  );

  Resource formula(
    String name, {
    Ensure ensure = Ensure.installed,
    Map<String, String> params = const {},
    List<String> requires = const [],
  }) => Resource(
    id: ResourceId('formula', name),
    ensure: ensure,
    params: params,
    requires: [for (final r in requires) ResourceId.parse(r)],
  );

  group('reading a preset as resources', () {
    test('every action a preset can hold has a state it was reaching for', () {
      // The mapping is what makes composition possible without a migration:
      // presets saved before blueprints existed have to read as declarations,
      // or every one of them would need rewriting by hand.
      expect(Ensure.fromAction(FormulaAction.install), Ensure.installed);
      expect(Ensure.fromAction(FormulaAction.verify), Ensure.installed);
      expect(Ensure.fromAction(FormulaAction.update), Ensure.latest);
      expect(Ensure.fromAction(FormulaAction.start), Ensure.running);
      expect(Ensure.fromAction(FormulaAction.restart), Ensure.running);
      expect(Ensure.fromAction(FormulaAction.stop), Ensure.stopped);
      expect(Ensure.fromAction(FormulaAction.uninstall), Ensure.absent);

      // Total, so no action can be added later without someone deciding what
      // state it means.
      for (final action in FormulaAction.values) {
        expect(
          () => Ensure.fromAction(action),
          returnsNormally,
          reason: '${action.name} has no declarative reading',
        );
      }
    });

    test('an existing preset composes with nothing rewritten', () {
      final resolved = resolver.resolve(blueprint(includes: ['dev-tools']), [
        preset('dev-tools', [
          step('dart', version: '3.13.3'),
          step('build-tools'),
        ]),
      ]);

      expect(
        [for (final r in resolved.resources) r.id.toString()],
        ['formula:dart', 'formula:build-tools'],
      );
      expect(resolved.resources.first.ensure, Ensure.installed);
      expect(resolved.resources.first.resource.version, '3.13.3');
      expect(
        resolved.resources.first.origin,
        'preset:dev-tools',
        reason:
            'the first question about an unexpected resource is who put it '
            'there',
      );
    });

    test('an include naming a preset nobody saved is refused', () {
      // Not skipped with a warning: a blueprint that half applies leaves a
      // machine in a state no document describes.
      expect(
        () => resolver.resolve(blueprint(includes: ['ghost']), const []),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('not saved on this Hub'),
          ),
        ),
      );
    });
  });

  group('composition and overriding', () {
    test('later wins, and local wins over everything it included', () {
      final resolved = resolver.resolve(
        blueprint(
          includes: ['base', 'extra'],
          resources: [formula('docker', ensure: Ensure.stopped)],
        ),
        [
          preset('base', [step('docker', action: FormulaAction.start)]),
          preset('extra', [step('docker', action: FormulaAction.install)]),
        ],
      );

      final docker = resolved.resources.single;
      expect(docker.ensure, Ensure.stopped);
      expect(docker.origin, 'local');
    });

    test('an override is recorded, never silent', () {
      // Overriding is the whole point of a base-plus-role split. It still has to
      // be visible, or a fleet quietly does something two documents disagree
      // about and the one you are reading is the one that lost.
      final resolved = resolver.resolve(
        blueprint(
          includes: ['base'],
          resources: [formula('docker', ensure: Ensure.stopped)],
        ),
        [
          preset('base', [step('docker', action: FormulaAction.start)]),
        ],
      );

      expect(resolved.resources.single.overrides, 'preset:base');
      expect(
        resolved.notes,
        contains('formula:docker: local overrides preset:base'),
      );
    });

    test('a resource declared once carries no override', () {
      final resolved = resolver.resolve(
        blueprint(resources: [formula('nmap')]),
        const [],
      );
      expect(resolved.resources.single.overrides, isNull);
      expect(resolved.notes, isEmpty);
    });
  });

  group('variables', () {
    test('a preset can read a var the including blueprint declares', () {
      // What makes a shared fragment parameterisable at all — otherwise every
      // pinned version forks the preset.
      final resolved = resolver.resolve(
        blueprint(
          includes: ['toolchain'],
          vars: {'sdk': '3.13.3'},
          resources: [
            formula('nmap', params: const {'version': r'${sdk}'}),
          ],
        ),
        [
          preset('toolchain', [step('dart', version: r'${sdk}')]),
        ],
      );

      for (final r in resolved.resources) {
        expect(r.resource.version, '3.13.3', reason: '${r.id}');
      }
    });

    test('an undeclared var is an error, not a literal', () {
      // A `${app_root}` that survived into a path would be created on a real
      // machine as a directory with a dollar sign in its name, and nobody would
      // find out until they went looking for why the deploy was empty.
      expect(
        () => resolver.resolve(
          blueprint(
            resources: [
              formula('dart', params: const {'version': r'${sdk}'}),
            ],
          ),
          const [],
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            allOf(contains(r'${sdk}'), contains('declares no such var')),
          ),
        ),
      );
    });
  });

  group('ordering', () {
    test('a resource is settled after everything it requires', () {
      final resolved = resolver.resolve(
        blueprint(
          resources: [
            formula('nmap', requires: ['formula:dart']),
            formula('build-tools', requires: ['formula:nmap']),
            formula('dart'),
          ],
        ),
        const [],
      );

      expect(
        [for (final r in resolved.resources) r.id.name],
        ['dart', 'nmap', 'build-tools'],
      );
    });

    test('independents keep declaration order, so a plan is reviewable', () {
      // Determinism is not cosmetic: a plan that reshuffles between runs cannot
      // be diffed, and a diff is how an operator decides whether to apply it.
      final subject = blueprint(
        resources: [formula('nmap'), formula('dart'), formula('build-tools')],
      );

      final first = resolver.resolve(subject, const []);
      final second = resolver.resolve(subject, const []);

      expect(
        [for (final r in first.resources) r.id.name],
        ['nmap', 'dart', 'build-tools'],
      );
      expect(
        [for (final r in second.resources) r.id.name],
        [for (final r in first.resources) r.id.name],
      );
    });

    test('a cycle is refused, and names the resources in it', () {
      expect(
        () => resolver.resolve(
          blueprint(
            resources: [
              formula('dart', requires: ['formula:nmap']),
              formula('nmap', requires: ['formula:dart']),
            ],
          ),
          const [],
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('dependency cycle'),
              contains('formula:dart'),
              contains('formula:nmap'),
            ),
          ),
        ),
      );
    });

    test('requiring something nothing declares is refused', () {
      // The author meant an ordering that will not happen. Half way through an
      // apply, on a real machine, is the expensive time to find that out.
      expect(
        () => resolver.resolve(
          blueprint(
            resources: [
              formula('dart', requires: ['formula:ghost']),
            ],
          ),
          const [],
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('requires formula:ghost, which nothing declares'),
          ),
        ),
      );
    });
  });

  group('what the Hub can refuse before a node ever sees it', () {
    test('a command formula cannot be asked to run', () {
      // `ensure: running` on something that manages no service can never
      // converge: it would plan a start on every apply, forever reporting drift
      // that applying does not fix. nmap's spec has no `start`, and the Hub
      // knows it.
      expect(
        () => resolver.resolve(
          blueprint(resources: [formula('nmap', ensure: Ensure.running)]),
          const [],
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('does not implement start'), contains('no service')),
          ),
        ),
      );
    });

    test('docker can, because it manages one', () {
      final resolved = resolver.resolve(
        blueprint(resources: [formula('docker', ensure: Ensure.running)]),
        const [],
      );
      expect(resolved.resources.single.ensure, Ensure.running);
    });

    test('a formula the Hub has never heard of is noted, not refused', () {
      // A site registers its own formulas. A Hub that refused everything not in
      // its own catalogue would make the system closed.
      final resolved = resolver.resolve(
        blueprint(resources: [formula('site-agent')]),
        const [],
      );
      expect(resolved.resources.single.id.name, 'site-agent');
      expect(resolved.notes.single, contains('not a built-in formula'));
    });
  });

  group('the hash', () {
    test('the same resources hash the same, every time', () {
      final subject = blueprint(
        includes: ['base'],
        resources: [formula('nmap')],
      );
      final presets = [
        preset('base', [step('dart')]),
      ];

      expect(
        resolver.resolve(subject, presets).hash,
        resolver.resolve(subject, presets).hash,
      );
      expect(resolver.resolve(subject, presets).hash, startsWith('sha256:'));
    });

    test('editing an included preset changes it', () {
      // The sharing dividend, made checkable: a node still carrying the old hash
      // is visibly behind, fleet-wide, without asking it anything.
      final subject = blueprint(includes: ['base']);

      final before = resolver.resolve(subject, [
        preset('base', [step('dart')]),
      ]);
      final after = resolver.resolve(subject, [
        preset('base', [step('dart'), step('net-tools')]),
      ]);

      expect(after.hash, isNot(before.hash));
    });

    test('renaming a blueprint does not', () {
      // Otherwise every node looks drifted because somebody fixed a typo in a
      // description, and drift stops meaning anything.
      final resources = [formula('dart')];
      final plain = Blueprint(
        id: BlueprintId('web'),
        name: 'Web',
        resources: resources,
      );
      final renamed = Blueprint(
        id: BlueprintId('web'),
        name: 'Web servers, production',
        description: 'Now with an explanation.',
        resources: resources,
      );

      expect(
        resolver.resolve(renamed, const []).hash,
        resolver.resolve(plain, const []).hash,
      );
    });

    test('the same ask from a different preset is a different fact', () {
      // Provenance is in the hash on purpose. "nginx is here because the base
      // hardening preset asks for it" and "…because this blueprint does" are
      // different states of the fleet, even though the machine looks identical.
      final fromBase = resolver.resolve(blueprint(includes: ['base']), [
        preset('base', [step('dart')]),
      ]);
      final fromLocal = resolver.resolve(
        blueprint(resources: [formula('dart')]),
        const [],
      );

      expect(fromLocal.hash, isNot(fromBase.hash));
    });
  });
}
