@TestOn('vm && !windows')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Drives `omnyserver ai …` as a subprocess with an isolated OMNYSERVER_HOME, so
/// the config lands in a temp dir, not the developer's real `~/.omnyserver`.
Future<ProcessResult> _omnyserver(List<String> args, {required String home}) =>
    Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/omnyserver.dart', ...args],
      environment: {'OMNYSERVER_HOME': home},
      includeParentEnvironment: true,
    );

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('omnyserver-ai-test'));
  tearDown(() => home.deleteSync(recursive: true));

  test('ai config writes ~/.omnyserver/ai.yaml', () async {
    final result = await _omnyserver([
      'ai', 'config', //
      '--provider', 'anthropic',
      '--model', 'claude-opus-4-8',
      '--key', 'sk-ant-secret9999',
    ], home: home.path);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final file = File(p.join(home.path, 'ai.yaml'));
    expect(file.existsSync(), isTrue);
    final yaml = file.readAsStringSync();
    expect(yaml, contains('provider: "anthropic"'));
    expect(yaml, contains('claude-opus-4-8'));
    // The key is written to the file, but masked in the command's output.
    expect(result.stdout as String, contains('••••9999'));
    expect(result.stdout as String, isNot(contains('sk-ant-secret9999')));
  });

  test('ai show reflects the written config, key masked', () async {
    await _omnyserver([
      'ai',
      'config',
      '--provider',
      'openai',
      '--key',
      'sk-openai-key',
    ], home: home.path);

    final result = await _omnyserver(['ai', 'show'], home: home.path);
    expect(result.exitCode, 0, reason: result.stderr as String);
    final out = result.stdout as String;
    expect(out, contains('provider: openai'));
    expect(out, contains('key:      set'));
    expect(out, isNot(contains('sk-openai-key')));
  });

  test('ai config with nothing to set is a clear error', () async {
    final result = await _omnyserver(['ai', 'config'], home: home.path);
    expect(result.exitCode, isNot(0));
    expect(result.stderr as String, contains('nothing to set'));
  });

  test('ai show on an unconfigured home says so', () async {
    final result = await _omnyserver(['ai', 'show'], home: home.path);
    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout as String, contains('(does not exist)'));
  });
}
