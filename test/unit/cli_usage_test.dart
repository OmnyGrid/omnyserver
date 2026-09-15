@TestOn('vm')
library;

import 'package:args/command_runner.dart';
import 'package:omnyserver/omnyserver_cli.dart';
import 'package:test/test.dart';

/// The help text is the CLI's documentation, and the only documentation most
/// people read. These walk every command the runner exposes and assert that it
/// describes itself — which is also the cheapest way to notice a command that
/// was wired up with nothing to say.
void main() {
  late CommandRunner<void> runner;

  setUp(() => runner = buildRunner());

  /// Every command and subcommand, depth-first.
  Iterable<Command<void>> walk(Iterable<Command<void>> commands) sync* {
    for (final command in commands) {
      yield command;
      yield* walk(command.subcommands.values);
    }
  }

  test('the top-level usage lists the command groups', () {
    expect(runner.usage, contains('omnyserver'));
    for (final name in const [
      'hub',
      'node',
      'nodes',
      'service',
      'ai',
      'preset',
      'formula',
      'state',
      'grant',
      'events',
      'ops',
      'alerts',
      'audit',
      'whoami',
      'cert',
    ]) {
      expect(runner.commands, contains(name));
    }
  });

  test('every command describes itself and shows its own usage', () {
    final seen = <String>[];
    for (final command in walk(runner.commands.values)) {
      seen.add(command.name);
      expect(
        command.description,
        isNotEmpty,
        reason: '${command.name} has no description',
      );
      expect(command.invocation, contains(command.name));
      expect(
        command.usage,
        contains(command.description.split('\n').first.substring(0, 8)),
        reason: '${command.name} usage omits its description',
      );
    }
    // A sanity floor: if the walk stopped finding subcommands this would pass
    // vacuously.
    expect(seen.length, greaterThan(40));
    expect(seen, containsAll(['start', 'install', 'reinstall', 'config']));
  });

  test('the service commands show worked examples, not just flags', () {
    final service = runner.commands['service']!;
    for (final sub in service.subcommands.values) {
      expect(
        sub.usageFooter,
        allOf(isNotNull, contains('Examples:'), contains('omnyserver service')),
        reason: sub.name,
      );
    }
  });
}
