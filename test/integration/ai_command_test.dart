@TestOn('vm && !windows')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/captured_stdout.dart';

/// `omnyserver ai …` drives the config file the Hub proxies `:ai` from.
///
/// Every case runs the real commands in this process and points them at a
/// temp file with `--path`, so nothing here reads or writes the developer's
/// own `~/.omnyserver/ai.yaml`.
void main() {
  late Directory home;
  late String configPath;

  setUp(() {
    home = Directory.systemTemp.createTempSync('omnyserver-ai-test');
    configPath = p.join(home.path, 'ai.yaml');
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<void> ai(List<String> args) =>
      buildRunner().run(['ai', ...args, '--path', configPath]);

  String yaml() => File(configPath).readAsStringSync();

  group('ai config', () {
    test('writes the provider, model and key', () async {
      await ai([
        'config', '--provider', 'anthropic', //
        '--model', 'claude-opus-4-8',
        '--key', 'sk-ant-secret9999',
      ]);

      expect(yaml(), contains('provider: "anthropic"'));
      expect(yaml(), contains('claude-opus-4-8'));
    });

    test('writes every per-phase model, and the agent knobs', () async {
      await ai([
        'config',
        '--provider', 'openai', //
        '--model', 'gpt-base',
        '--planner-model', 'gpt-planner',
        '--executor-model', 'gpt-executor',
        '--explainer-model', 'gpt-explainer',
        '--mode', 'plan',
        '--language', 'portuguese',
        '--base-url', 'https://proxy.example.com',
        '--max-steps', '12',
        '--key', 'sk-openai-key',
      ]);

      expect(
        yaml(),
        stringContainsInOrder(['gpt-planner', 'gpt-executor', 'gpt-explainer']),
      );

      final shown = await captureStdout(() => ai(['show']));
      expect(shown, contains('provider: openai'));
      expect(shown, contains('planner:  gpt-planner'));
      expect(shown, contains('executor: gpt-executor'));
      expect(shown, contains('explainer: gpt-explainer'));
      expect(shown, contains('mode:     plan'));
      expect(shown, contains('language: portuguese'));
      expect(shown, contains('baseUrl:  https://proxy.example.com'));
      expect(shown, contains('maxSteps: 12'));
      // The key is written to the file, but never echoed back whole.
      expect(shown, isNot(contains('sk-openai-key')));
    });

    test(
      '"default", "off" and "none" clear a value back to the default',
      () async {
        await ai([
          'config',
          '--provider', 'gemini', //
          '--model', 'gemini-pro',
          '--language', 'german',
          '--base-url', 'https://proxy.example.com',
        ]);

        final out = await captureStdout(
          () => ai([
            'config',
            '--model', 'default', //
            '--language', 'off',
            '--base-url', 'none',
          ]),
        );
        expect(out, contains('model: (cleared — uses default)'));
        expect(out, contains('language: (cleared — uses default)'));
        expect(out, contains('baseUrl: (cleared — uses default)'));

        final shown = await captureStdout(() => ai(['show']));
        expect(shown, contains('language: (model default)'));
        expect(shown, contains('baseUrl:  (provider default)'));
      },
    );

    test('a short key is masked rather than half-shown', () async {
      final out = await captureStdout(
        () => ai(['config', '--provider', 'anthropic', '--key', 'ab']),
      );
      expect(out, contains('key: ••••'));
      expect(out, isNot(contains('ab')));
    });

    test('a long key shows only its last four characters', () async {
      final out = await captureStdout(
        () => ai(['config', '--provider', 'anthropic', '--key', 'sk-ant-9999']),
      );
      expect(out, contains('••••9999'));
      expect(out, isNot(contains('sk-ant-9999')));
    });

    test('--key - reads the key from a prompt, not the command line', () async {
      final out = await captureStdio(
        () => ai(['config', '--provider', 'anthropic', '--key', '-']),
        lines: ['  sk-ant-prompted9999  '],
      );

      expect(out, contains('API key: '));
      // Trimmed, stored, and echoed back masked.
      expect(out, contains('••••9999'));
      expect(out, isNot(contains('sk-ant-prompted9999')));
      expect(yaml(), contains('sk-ant-prompted9999'));
    });

    test(
      'an empty answer at the prompt is refused, not stored as blank',
      () async {
        await expectLater(
          captureStdio(
            () => ai(['config', '--provider', 'anthropic', '--key', '-']),
            lines: ['   '],
          ),
          throwsA(
            isA<CliError>().having(
              (e) => e.message,
              'message',
              contains('no key entered'),
            ),
          ),
        );
      },
    );

    test('an unknown --provider is refused', () async {
      await expectLater(
        ai(['config', '--provider', 'anthropic', '--model', 'x']),
        completes,
      );
      // `allowed:` rejects an unknown value at parse time, which is a usage
      // error rather than a CliError — the CLI's own exit-code 64 path.
      await expectLater(
        ai(['config', '--provider', 'not-a-provider']),
        throwsA(isA<Exception>()),
      );
    });

    test('an unknown --mode is refused', () async {
      await expectLater(
        ai(['config', '--mode', 'sideways']),
        throwsA(isA<Exception>()),
      );
    });

    test('--max-steps must be a positive integer', () async {
      for (final bad in ['zero', '0', '-3']) {
        await expectLater(
          ai(['config', '--max-steps', bad]),
          throwsA(
            isA<CliError>().having(
              (e) => e.message,
              'message',
              contains('--max-steps'),
            ),
          ),
          reason: bad,
        );
      }
    });

    test('with nothing to set it says so instead of writing a file', () async {
      await expectLater(
        ai(['config']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('nothing to set'),
          ),
        ),
      );
      expect(File(configPath).existsSync(), isFalse);
    });
  });

  group('ai show', () {
    test('on an unconfigured path says the file does not exist', () async {
      final out = await captureStdout(() => ai(['show']));
      expect(out, contains('(does not exist)'));
      expect(out, contains('provider: (unset)'));
      expect(out, contains('key:      not set'));
    });

    test('reports a key that is set, without printing it', () async {
      await ai(['config', '--provider', 'anthropic', '--key', 'sk-ant-key']);
      final out = await captureStdout(() => ai(['show']));
      expect(out, contains('key:      set'));
      expect(out, isNot(contains('sk-ant-key')));
    });
  });

  group('ai test', () {
    test('on an unconfigured path says how to configure it', () async {
      await expectLater(
        ai(['test']),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('not configured'),
          ),
        ),
      );
    });

    test('a working key and model are reported one line each', () async {
      final provider = await _fakeAnthropic(
        (request) => (200, '{"content":[{"type":"text","text":"pong"}]}'),
      );
      addTearDown(() => provider.close(force: true));

      await ai([
        'config',
        '--provider', 'anthropic', //
        '--key', 'sk-ant-key',
        '--model', 'claude-test',
        '--base-url', 'http://127.0.0.1:${provider.port}',
      ]);

      final out = await captureStdout(() => ai(['test']));
      expect(out, contains('Validating anthropic'));
      expect(out, contains('✓ claude-test'));
      expect(out, contains('OK — key and model(s) valid'));
    });

    test('a rejected key fails visibly, naming the model', () async {
      final provider = await _fakeAnthropic(
        (request) => (401, '{"error":{"message":"invalid x-api-key"}}'),
      );
      addTearDown(() => provider.close(force: true));

      await ai([
        'config',
        '--provider', 'anthropic', //
        '--key', 'sk-ant-wrong',
        '--model', 'claude-test',
        '--base-url', 'http://127.0.0.1:${provider.port}',
      ]);

      final out = StringBuffer();
      await expectLater(
        captureStdout(() => ai(['test']), into: out),
        throwsA(
          isA<CliError>().having(
            (e) => e.message,
            'message',
            contains('validation failed'),
          ),
        ),
      );
      expect(out.toString(), contains('✗ claude-test'));
    });
  });

  test('the default config path sits under the OmnyServer home', () {
    expect(
      omnyServerAiConfigPath(),
      endsWith(p.join('.omnyserver', 'ai.yaml')),
    );
    // An explicit path wins, and an all-whitespace one does not.
    expect(omnyServerAiConfigPath('/tmp/x.yaml'), '/tmp/x.yaml');
    expect(omnyServerAiConfigPath('   '), omnyServerAiConfigPath());
  });
}

/// A stand-in for the Anthropic Messages API on loopback, answering every
/// request with what [reply] returns — so `ai test` exercises a real HTTP
/// round trip without a key, a network or a bill.
Future<HttpServer> _fakeAnthropic(
  (int, String) Function(HttpRequest request) reply,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await request.drain<void>();
    final (status, body) = reply(request);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(body);
    await request.response.close();
  });
  return server;
}
