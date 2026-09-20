@TestOn('vm')
library;

import 'package:omnyserver/omnyserver.dart';
import 'package:test/test.dart';

/// The blueprint model: identity, the wire form, and the two pieces of
/// behaviour that live in the entities rather than in a service.
void main() {
  final now = DateTime.utc(2026, 9, 19, 12);

  ResourceId id(String value) => ResourceId.parse(value);

  group('ResourceId', () {
    test('splits on the first colon, so a name may contain one', () {
      // Names are paths and URLs as often as they are words, and both carry
      // colons. Splitting on the last one would turn a Windows path into a type.
      final file = id('file:C:/ProgramData/omny/agent.conf');
      expect(file.type, 'file');
      expect(file.name, 'C:/ProgramData/omny/agent.conf');
      expect(file.toString(), 'file:C:/ProgramData/omny/agent.conf');
    });

    test('is compared by value, because it keys the ledger', () {
      expect(id('formula:docker'), ResourceId('formula', 'docker'));
      expect(
        {id('formula:docker')}.contains(ResourceId('formula', 'docker')),
        isTrue,
      );
      expect(id('formula:docker'), isNot(id('formula:dart')));
    });

    test('a type is normalised, a name is left alone', () {
      // A type is a provider lookup, so case is noise. A name can be a path, and
      // lower-casing `/Users/Ana` would point at a different file.
      expect(ResourceId('Formula', 'Docker').type, 'formula');
      expect(ResourceId('formula', 'Docker').name, 'Docker');
    });

    test('malformed ids are refused with the shape they should have had', () {
      expect(() => id('docker'), throwsA(isA<ProtocolException>()));
      expect(() => id(':docker'), throwsA(isA<ProtocolException>()));
      expect(
        () => ResourceId('formula', '  '),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => id('docker'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('"type:name"'),
          ),
        ),
      );
    });
  });

  group('the authored form', () {
    test('a resource can write its settings inline', () {
      // `version: "3.13.3"` next to the name reads far better in a file than
      // nesting it under `params`, and a blueprint is a document a person edits.
      final resource = Resource.fromJson(const {
        'type': 'formula',
        'name': 'dart',
        'ensure': 'installed',
        'version': '3.13.3',
      });

      expect(resource.id.toString(), 'formula:dart');
      expect(resource.version, '3.13.3');
    });

    test('an unknown ensure is refused rather than guessed', () {
      // There is no safe default: guessing would silently do something other
      // than what the blueprint asked for.
      expect(
        () => Resource.fromJson(const {
          'type': 'formula',
          'name': 'dart',
          'ensure': 'instaled',
        }),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('instaled'),
          ),
        ),
      );
    });

    test('a blueprint survives the round trip it will actually make', () {
      final blueprint = Blueprint(
        id: BlueprintId('web-server'),
        name: 'Web server',
        description: 'nginx and the app behind it.',
        platforms: const ['linux'],
        includes: [PresetId('base-hardening')],
        vars: const {'sdk': '3.13.3'},
        resources: [
          Resource(
            id: ResourceId('formula', 'dart'),
            ensure: Ensure.installed,
            params: const {'version': r'${sdk}'},
            requires: [ResourceId('formula', 'build-tools')],
          ),
        ],
      );

      final back = Blueprint.fromJson(blueprint.toJson());

      expect(back.id, blueprint.id);
      expect(back.platforms, ['linux']);
      expect(back.includes.single.value, 'base-hardening');
      expect(back.vars, {'sdk': '3.13.3'});
      expect(back.resources.single.params, {'version': r'${sdk}'});
      expect(
        back.resources.single.requires.single.toString(),
        'formula:build-tools',
      );
    });

    test('the heading key is `blueprint`, and `id` still decodes', () {
      // `blueprint: web-server` reads as a heading at the top of a file, which
      // is where it is written. The API's own habit is `id`, so both work.
      expect(
        Blueprint.fromJson(const {'blueprint': 'web', 'name': 'Web'}).id.value,
        'web',
      );
      expect(
        Blueprint.fromJson(const {'id': 'web', 'name': 'Web'}).id.value,
        'web',
      );
    });

    test('the source survives, so a YAML blueprint reads back as YAML', () {
      // The rule is that a blueprint's format is fixed when it is authored.
      // Storing the bytes is what keeps comments — a re-rendering would not.
      final source = const BlueprintSource(
        format: BlueprintFormat.yaml,
        text: '# the hardened base\nblueprint: web\n',
      );
      final back = Blueprint.fromJson(
        Blueprint(
          id: BlueprintId('web'),
          name: 'Web',
        ).withSource(source).toJson(),
      );

      expect(back.source!.format, BlueprintFormat.yaml);
      expect(back.source!.text, contains('# the hardened base'));
    });
  });

  group('whether a reading already satisfies a declaration', () {
    ResourceState state(FormulaStatus status) => ResourceState(
      id: ResourceId('formula', 'docker'),
      status: status,
      checkedAt: now,
    );

    test('present covers installed, running and stopped alike', () {
      for (final status in [
        FormulaStatus.installed,
        FormulaStatus.running,
        FormulaStatus.stopped,
      ]) {
        expect(
          state(status).satisfies(Ensure.present),
          isTrue,
          reason: '$status',
        );
        expect(state(status).satisfies(Ensure.installed), isTrue);
      }
      expect(state(FormulaStatus.absent).satisfies(Ensure.installed), isFalse);
    });

    test('running and stopped are distinguished', () {
      expect(state(FormulaStatus.running).satisfies(Ensure.running), isTrue);
      expect(state(FormulaStatus.stopped).satisfies(Ensure.running), isFalse);
      expect(state(FormulaStatus.stopped).satisfies(Ensure.stopped), isTrue);
      // Installed-but-not-a-service is not running, which is what `stopped`
      // asked for.
      expect(state(FormulaStatus.installed).satisfies(Ensure.stopped), isTrue);
    });

    test('absent is satisfied only by being genuinely absent', () {
      expect(state(FormulaStatus.absent).satisfies(Ensure.absent), isTrue);
      expect(state(FormulaStatus.installed).satisfies(Ensure.absent), isFalse);
    });

    test('unknown satisfies nothing at all', () {
      // The rule that matters most. A probe that could not run has said nothing,
      // and treating silence as agreement is how a blind node reports converged.
      for (final ensure in Ensure.values) {
        expect(
          state(FormulaStatus.unknown).satisfies(ensure),
          isFalse,
          reason: 'unknown should not satisfy ${ensure.name}',
        );
      }
    });

    test('latest is never already satisfied', () {
      // "The newest version" cannot be known without asking the package manager.
      // Claiming convergence from a reading would pin a node to whatever it had
      // and call it up to date.
      expect(state(FormulaStatus.running).satisfies(Ensure.latest), isFalse);
      expect(state(FormulaStatus.installed).satisfies(Ensure.latest), isFalse);
    });

    test('a probe that could not run is unknown by construction', () {
      final unreadable = ResourceState.unknown(
        ResourceId('formula', 'docker'),
        now,
        message: 'no shell',
      );
      expect(unreadable.status, FormulaStatus.unknown);
      expect(unreadable.isPresent, isFalse);
    });
  });

  group('the ledger', () {
    ResolvedBlueprint resolved(List<String> names) => ResolvedBlueprint(
      blueprint: BlueprintId('web'),
      hash: 'sha256:x',
      resources: [
        for (final name in names)
          ResolvedResource(
            resource: Resource(
              id: ResourceId('formula', name),
              ensure: Ensure.installed,
            ),
            origin: 'local',
          ),
      ],
    );

    test('it names what the blueprint has stopped declaring', () {
      // The reason a blueprint can be *edited* and not only added to. Delete a
      // resource and the document no longer mentions it, so the document cannot
      // ask for its removal — only this record can.
      final ledger = Ledger.empty(
        BlueprintId('web'),
        now,
      ).recording(resolved(['dart', 'nmap']), now, adopted: const {});

      final orphans = ledger.orphansOf(resolved(['dart']));

      expect([for (final o in orphans) o.id.name], ['nmap']);
    });

    test('orphans come back in reverse order, to tear down safely', () {
      // Creation order was dependency order; removal has to run it backwards, or
      // a thing is removed while something still standing depends on it.
      final ledger = Ledger.empty(BlueprintId('web'), now).recording(
        resolved(['dart', 'build-tools', 'nmap']),
        now,
        adopted: const {},
      );

      expect(
        [for (final o in ledger.orphansOf(resolved([]))) o.id.name],
        ['nmap', 'build-tools', 'dart'],
      );
    });

    test('a resource declared absent is not recorded as managed', () {
      // "Make sure this is gone" is not ownership. Recording it would mean
      // unassigning the blueprint tried to remove something it never put there.
      final ledger = Ledger.empty(BlueprintId('web'), now).recording(
        ResolvedBlueprint(
          blueprint: BlueprintId('web'),
          hash: 'sha256:x',
          resources: [
            ResolvedResource(
              resource: Resource(
                id: ResourceId('formula', 'nmap'),
                ensure: Ensure.absent,
              ),
              origin: 'local',
            ),
          ],
        ),
        now,
        adopted: const {},
      );

      expect(ledger.entries, isEmpty);
    });

    test('adoption sticks across later applies', () {
      // If nginx was on this box a year before anyone wrote a blueprint,
      // unassigning must not uninstall it — and that fact does not stop being
      // true because a later apply touched something else.
      final first = Ledger.empty(BlueprintId('web'), now).recording(
        resolved(['dart']),
        now,
        adopted: {ResourceId('formula', 'dart')},
      );
      expect(first.entries[ResourceId('formula', 'dart')]!.adopted, isTrue);

      final second = first.recording(
        resolved(['dart', 'nmap']),
        now,
        adopted: const {},
      );
      expect(second.entries[ResourceId('formula', 'dart')]!.adopted, isTrue);
      expect(second.entries[ResourceId('formula', 'nmap')]!.adopted, isFalse);
    });

    test('it survives the round trip to the node data dir', () {
      final ledger = Ledger.empty(BlueprintId('web'), now).recording(
        resolved(['dart']),
        now,
        adopted: {ResourceId('formula', 'dart')},
      );

      final back = Ledger.fromJson(ledger.toJson());

      expect(back.blueprint.value, 'web');
      expect(back.hash, 'sha256:x');
      expect(back.entries.keys.single.toString(), 'formula:dart');
      expect(back.entries.values.single.adopted, isTrue);
    });
  });

  group('changes', () {
    test('a change round-trips, logs and all', () {
      final change = ResourceChange(
        id: ResourceId('formula', 'dart'),
        kind: ChangeKind.create,
        reason: 'not installed',
        origin: 'preset:dev-tools',
      );
      final back = ResourceChange.fromJson(
        change.withLogs(const ['fetching', 'done']).toJson(),
      );

      expect(back.id.toString(), 'formula:dart');
      expect(back.kind, ChangeKind.create);
      expect(back.reason, 'not installed');
      expect(back.origin, 'preset:dev-tools');
      expect(back.logs, ['fetching', 'done']);
    });

    test('only three kinds would touch the machine', () {
      // What a dry run counts, and what an operator is being asked to approve.
      expect(
        [
          for (final k in ChangeKind.values)
            if (k.isWork) k.name,
        ],
        ['create', 'update', 'remove'],
      );
    });
  });
}
