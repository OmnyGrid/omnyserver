import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:http/http.dart' as http;
import 'package:omnyshell/omnyshell_client.dart' as ai;
import 'package:path/path.dart' as p;

import '../shared/utils/omnyserver_home.dart';
import 'cli_error.dart';

/// The AI config file the Hub proxies from, and `ai config` writes to.
///
/// omnyserver keeps its own, under `OMNYSERVER_HOME` (`~/.omnyserver/ai.yaml`),
/// separate from the OmnyShell CLI's `~/.omnyshell/ai.yaml`. An explicit
/// `--path` overrides it.
String omnyServerAiConfigPath([String? explicit]) {
  final trimmed = explicit?.trim();
  if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  return p.join(OmnyServerHome.resolve(), 'ai.yaml');
}

/// `omnyserver ai …` — configure the AI provider the Hub uses to proxy `:ai`
/// (and `:ide`) requests for web clients.
class AiCliCommand extends Command<void> {
  /// Creates the ai command group.
  AiCliCommand() {
    addSubcommand(AiConfigCommand());
    addSubcommand(AiShowCommand());
    addSubcommand(AiTestCommand());
  }

  @override
  String get name => 'ai';

  @override
  String get description =>
      'Configure the AI provider the Hub proxies for web clients '
      '(~/.omnyserver/ai.yaml).';
}

/// `omnyserver ai config`
class AiConfigCommand extends Command<void> {
  /// Creates the ai-config command.
  AiConfigCommand() {
    argParser
      ..addOption(
        'provider',
        allowed: ['anthropic', 'openai', 'gemini'],
        help: 'AI provider.',
      )
      ..addOption(
        'model',
        help:
            'Shared model id (e.g. claude-opus-4-8). Pass "default" to clear it '
            'back to the per-provider default.',
      )
      ..addOption(
        'planner-model',
        help:
            'Stronger model for planning (falls back to model). '
            '"default" clears.',
      )
      ..addOption(
        'executor-model',
        help:
            'Cheaper model for running commands (falls back to model). '
            '"default" clears.',
      )
      ..addOption(
        'explainer-model',
        help:
            'Model for explaining a command (falls back to model). '
            '"default" clears.',
      )
      ..addOption(
        'key',
        help:
            'API key. Use "-" to read it from a hidden prompt instead of the '
            'command line.',
      )
      ..addOption(
        'mode',
        allowed: ['standard', 'plan', 'auto'],
        help: 'Default agent mode.',
      )
      ..addOption(
        'language',
        help: 'Reply language (free-form, e.g. portuguese). "off" clears it.',
      )
      ..addOption(
        'base-url',
        help: 'Override the provider API base URL. "default" clears it.',
      )
      ..addOption('max-steps', help: 'Agent loop bound (positive integer).')
      ..addOption(
        'path',
        help: 'Config file path (default ~/.omnyserver/ai.yaml).',
      );
  }

  @override
  String get name => 'config';

  @override
  String get description => 'Set the AI provider, model, key, mode and more.';

  @override
  Future<void> run() async {
    final args = argResults!;

    final providerArg = args['provider'] as String?;
    final provider = providerArg == null
        ? null
        : ai.AiProviderKind.tryParse(providerArg);
    if (providerArg != null && provider == null) {
      throw CliError('invalid --provider: $providerArg');
    }

    final modeArg = args['mode'] as String?;
    final mode = modeArg == null ? null : ai.AgentMode.tryParse(modeArg);
    if (modeArg != null && mode == null) {
      throw CliError('invalid --mode: $modeArg');
    }

    int? maxSteps;
    final maxStepsArg = args['max-steps'] as String?;
    if (maxStepsArg != null) {
      maxSteps = int.tryParse(maxStepsArg.trim());
      if (maxSteps == null || maxSteps <= 0) {
        throw CliError(
          'invalid --max-steps: $maxStepsArg (expected a positive integer)',
        );
      }
    }

    var key = args['key'] as String?;
    if (key == '-') {
      key = _readSecret('API key: ');
      if (key.isEmpty) throw CliError('no key entered');
    }

    // null = not provided; '' = clear back to the default; else the value.
    String? clearable(String name) {
      final raw = (args[name] as String?)?.trim();
      if (raw == null) return null;
      final v = raw.toLowerCase();
      return (raw.isEmpty || v == 'off' || v == 'none' || v == 'default')
          ? ''
          : raw;
    }

    final model = clearable('model');
    final plannerModel = clearable('planner-model');
    final executorModel = clearable('executor-model');
    final explainerModel = clearable('explainer-model');
    final baseUrl = clearable('base-url');
    final language = clearable('language');

    bool blank(String? s) => s == null || s.isEmpty;

    if (provider == null &&
        model == null &&
        plannerModel == null &&
        executorModel == null &&
        explainerModel == null &&
        blank(key) &&
        mode == null &&
        language == null &&
        baseUrl == null &&
        maxSteps == null) {
      throw CliError(
        'nothing to set — pass at least one of --provider/--model/'
        '--planner-model/--executor-model/--explainer-model/--key/--mode/'
        '--language/--base-url/--max-steps. Pass "default" to clear a value. '
        'See: omnyserver ai config --help',
      );
    }

    final path = omnyServerAiConfigPath(args['path'] as String?);
    ai.AiConfigIo.write(
      provider: provider,
      model: model,
      plannerModel: plannerModel,
      executorModel: executorModel,
      explainerModel: explainerModel,
      apiKey: blank(key) ? null : key,
      mode: mode,
      language: language,
      baseUrl: baseUrl,
      maxSteps: maxSteps,
      path: path,
    );

    void report(String label, String? value) {
      if (value == null) return;
      stdout.writeln(
        '  $label: ${value.isEmpty ? '(cleared — uses default)' : value}',
      );
    }

    stdout.writeln('Wrote $path');
    if (provider != null) stdout.writeln('  provider: ${provider.wireName}');
    report('model', model);
    report('plannerModel', plannerModel);
    report('executorModel', executorModel);
    report('explainerModel', explainerModel);
    if (!blank(key)) stdout.writeln('  key: ${_maskKey(key!)}');
    if (mode != null) stdout.writeln('  mode: ${mode.wireName}');
    report('language', language);
    report('baseUrl', baseUrl);
    if (maxSteps != null) stdout.writeln('  maxSteps: $maxSteps');
    stdout.writeln('Start the Hub with --shell to serve it to web clients.');
  }
}

/// `omnyserver ai show`
class AiShowCommand extends Command<void> {
  /// Creates the ai-show command.
  AiShowCommand() {
    argParser.addOption(
      'path',
      help: 'Config file path (default ~/.omnyserver/ai.yaml).',
    );
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show the resolved AI configuration (key masked).';

  @override
  Future<void> run() async {
    final d = ai.AiConfigIo.describe(
      path: omnyServerAiConfigPath(argResults!['path'] as String?),
    );

    stdout
      ..writeln(
        'Config file: ${d.path}${d.fileExists ? '' : ' (does not exist)'}',
      )
      ..writeln('provider: ${d.provider?.wireName ?? '(unset)'}')
      ..writeln(
        'model:    ${d.model ?? '(default)'}'
        '${d.modelFromDefault ? '  [default]' : ''}',
      )
      ..writeln('  planner:  ${d.plannerModel ?? '(uses model)'}')
      ..writeln('  executor: ${d.executorModel ?? '(uses model)'}')
      ..writeln('  explainer: ${d.explainerModel ?? '(uses model)'}')
      ..writeln('mode:     ${d.mode.wireName}')
      ..writeln('language: ${d.language ?? '(model default)'}')
      ..writeln('baseUrl:  ${d.baseUrl ?? '(provider default)'}')
      ..writeln('maxSteps: ${d.maxSteps}');
    if (d.keySet) {
      final src = d.keyFromEnv ? d.keyEnvVar : 'ai.yaml';
      stdout.writeln('key:      set (from $src)');
    } else {
      stdout.writeln(
        'key:      not set'
        '${d.keyEnvVar == null ? '' : ' (set ${d.keyEnvVar} or run: '
                  'omnyserver ai config --key -)'}',
      );
    }
  }
}

/// `omnyserver ai test`
class AiTestCommand extends Command<void> {
  /// Creates the ai-test command.
  AiTestCommand() {
    argParser.addOption(
      'path',
      help: 'Config file path (default ~/.omnyserver/ai.yaml).',
    );
  }

  @override
  String get name => 'test';

  @override
  String get description =>
      'Validate the API key and models with a live provider request.';

  @override
  Future<void> run() async {
    final cfg = ai.AiConfigIo.load(
      path: omnyServerAiConfigPath(argResults!['path'] as String?),
    );
    if (cfg == null) {
      throw CliError(
        'AI is not configured. Set a key (ANTHROPIC_API_KEY / OPENAI_API_KEY / '
        'GEMINI_API_KEY) or run: omnyserver ai config --help',
      );
    }

    final models = <String>{
      cfg.modelFor(ai.AgentPhase.planning),
      cfg.modelFor(ai.AgentPhase.executing),
    }.toList();

    stdout.writeln(
      'Validating ${cfg.provider.wireName} with ${models.length} model(s)…',
    );

    final provider = ai.providerFor(cfg, http.Client());
    try {
      final results = await ai.validateModels(provider, models);
      var anyFail = false;
      for (final r in results) {
        if (r.ok) {
          final ms = r.latencyMs == null ? '' : '  (${r.latencyMs} ms)';
          stdout.writeln('  ✓ ${r.model}$ms');
        } else {
          anyFail = true;
          stdout.writeln('  ✗ ${r.model}: ${r.error}');
        }
      }
      if (anyFail) throw CliError('validation failed for one or more models.');
      stdout.writeln('OK — key and model(s) valid.');
    } finally {
      provider.close();
    }
  }
}

/// Masks an API key, revealing only the last 4 characters.
String _maskKey(String key) =>
    key.length <= 4 ? '••••' : '••••${key.substring(key.length - 4)}';

/// Reads a line with terminal echo disabled (when attached), so a secret never
/// appears on screen or in shell history.
String _readSecret(String prompt) {
  stdout.write(prompt);
  final hadEcho = stdin.hasTerminal ? stdin.echoMode : null;
  if (hadEcho != null) stdin.echoMode = false;
  try {
    final line = stdin.readLineSync() ?? '';
    return line.trim();
  } finally {
    if (hadEcho != null) {
      stdin.echoMode = hadEcho;
      stdout.writeln();
    }
  }
}
