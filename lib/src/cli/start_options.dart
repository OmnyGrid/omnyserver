import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../shared/utils/omnyserver_home.dart';
import 'cli_error.dart';

// ---------------------------------------------------------------------------
// The `hub start` / `node start` option sets.
//
// Declared here rather than inline in the commands because `service install`
// has to register the *same* options on its own parser — it reconstructs the
// `omnyserver <role> start …` command line and bakes it into the OS service
// definition. Two declarations would drift; one cannot.
// ---------------------------------------------------------------------------

/// Adds the `hub start` options to [parser].
///
/// [includeShellPath] and [includeDataDir] exist for the merged `service`
/// parser, which accepts either role's options and so must register the names
/// both roles declare exactly once. See `service_commands.dart`.
void addHubStartOptions(
  ArgParser parser, {
  bool includeShellPath = true,
  bool includeDataDir = true,
}) {
  parser
    ..addOption('host', defaultsTo: '0.0.0.0', help: 'TLS bind host.')
    ..addOption('port', defaultsTo: '8443', help: 'TLS bind port.')
    ..addOption(
      'cert',
      help: 'TLS certificate chain (PEM). Required unless --tls-dir is set.',
    )
    ..addOption(
      'key',
      help: 'TLS private key (PEM). Required unless --tls-dir is set.',
    )
    ..addOption(
      'tls-dir',
      help:
          'Directory holding the listener certificate (fullchain.pem + '
          'privkey.pem, LetsEncrypt layout), as an alternative to '
          '--cert/--key. Re-checked periodically and reloaded automatically '
          'when the files change (e.g. on renewal).',
    )
    ..addOption(
      'node-path',
      defaultsTo: '/node',
      help: 'Path the node control channel is mounted at.',
    )
    ..addFlag(
      'shell',
      negatable: false,
      help: 'Also serve OmnyShell nodes (same port, same certificate).',
    );
  if (includeShellPath) {
    parser.addOption(
      'shell-path',
      defaultsTo: '/shell',
      help: 'Path the OmnyShell broker is mounted at.',
    );
  }
  parser
    ..addOption('api-token', help: 'Bearer token required by the HTTP API.')
    ..addMultiOption(
      'grant',
      help: 'Token grant "principal:token:role1,role2" (repeatable).',
    )
    ..addMultiOption(
      'alert',
      help:
          'A condition worth being told about (repeatable): "disk>90", '
          '"cpu>95 for 5m", "offline for 2m". None by default — a tool that '
          'invents its own thresholds is a tool that pages you at 3am.',
    );
  if (includeDataDir) {
    parser.addOption('data-dir', help: hubDataDirHelp);
  }
  parser
    ..addFlag('ephemeral', negatable: false, help: ephemeralHelp)
    ..addMultiOption(
      'cors-origin',
      help:
          'Browser origin allowed to call the HTTP API, e.g. '
          'https://dashboard.example.com (repeatable). Required for a web '
          'dashboard — a browser is always a different origin than the Hub.',
    );
}

/// The help text for the Hub's `--data-dir`, shared with the `service` parser.
const String hubDataDirHelp =
    'Directory to persist the Hub in (nodes, audit, metrics, desired state, '
    'issued credentials). Defaults to <OMNYSERVER_HOME>/hub, i.e. '
    '~/.omnyserver/hub. Pass --ephemeral for an in-memory Hub instead.';

/// The help text for `--ephemeral`, shared with the `service` parser.
const String ephemeralHelp =
    'Keep everything in memory: a restart forgets the fleet, the audit trail '
    'and every credential issued with `grant add`. Mutually exclusive with '
    '--data-dir.';

/// Adds the `node start` options to [parser].
///
/// [includeShellPath] exists for the merged `service` parser — `shell-path` is
/// the one option name both roles declare, so only one of the two helpers may
/// register it.
void addNodeStartOptions(ArgParser parser, {bool includeShellPath = true}) {
  parser
    ..addOption('hub', help: 'Hub WSS URL, e.g. wss://hub:8443.')
    ..addOption('id', help: 'Node id.')
    ..addOption('principal', defaultsTo: 'node-account', help: 'Principal.')
    ..addOption('token', help: 'Bearer token.')
    ..addOption('ca', help: 'Trusted CA certificate (PEM).')
    ..addFlag(
      'insecure',
      negatable: false,
      help: 'Accept any TLS certificate (dev only).',
    )
    ..addFlag(
      'with-shell',
      negatable: false,
      help: 'Also run an OmnyShell node, so the Hub can open shell sessions.',
    );
  if (includeShellPath) {
    parser.addOption(
      'shell-path',
      defaultsTo: '/shell',
      help: "Path of the Hub's OmnyShell broker (with --with-shell).",
    );
  }
  parser
    ..addFlag(
      'ship-logs',
      defaultsTo: true,
      help:
          "Send the agent's own log lines to the Hub, so `node logs` can read "
          'them without logging into the machine.',
    )
    ..addMultiOption(
      'label',
      help:
          'Node label "key=value" (repeatable), e.g. env=prod. Labels are how '
          'a fleet is addressed: they filter `nodes list` and select the '
          'targets of `formula run` and `preset apply`.',
    )
    ..addMultiOption(
      'shell-label',
      help:
          'OmnyShell node label "key=value" (repeatable), e.g. '
          'allow-roles=admin.',
    );
}

// ---------------------------------------------------------------------------
// Validation, shared by `<role> start` and `service install <role>`.
// ---------------------------------------------------------------------------

/// Validates the Hub's TLS source — exactly one of `--tls-dir` or
/// (`--cert` + `--key`), never neither (the Hub has no insecure mode).
/// Returns the trimmed `--tls-dir` in directory mode, otherwise `null`.
String? validateHubTls(ArgResults args) {
  final tlsDir = (args['tls-dir'] as String?)?.trim();
  final cert = args['cert'] as String?;
  final key = args['key'] as String?;
  final hasCertOrKey =
      (cert != null && cert.isNotEmpty) || (key != null && key.isNotEmpty);

  if (tlsDir != null && tlsDir.isNotEmpty) {
    if (hasCertOrKey) {
      throw CliError('use either --tls-dir or --cert/--key, not both');
    }
    if (!File('$tlsDir/fullchain.pem').existsSync() ||
        !File('$tlsDir/privkey.pem').existsSync()) {
      throw CliError(
        '--tls-dir "$tlsDir" must contain fullchain.pem and privkey.pem',
      );
    }
    return tlsDir;
  }

  if (cert == null || cert.isEmpty || key == null || key.isEmpty) {
    throw CliError(
      '--cert and --key are required unless --tls-dir is set '
      '(try: omnyserver cert gen)',
    );
  }
  return null;
}

/// Validates that [args] carries what a Node agent needs to start.
void validateNodeStartArgs(ArgResults args) {
  final hub = args['hub'] as String?;
  final id = args['id'] as String?;
  final token = args['token'] as String?;
  if (hub == null || id == null || token == null) {
    throw CliError('--hub, --id and --token are required');
  }
}

// ---------------------------------------------------------------------------
// The data directory.
// ---------------------------------------------------------------------------

/// The machine-wide data root for a `--system` service: `/var/lib/omnyserver`
/// on POSIX, `%ProgramData%\omnyserver` on Windows (which has no `/var/lib`).
String systemDataDir() {
  if (!Platform.isWindows) return '/var/lib/omnyserver';
  final programData = Platform.environment['ProgramData'];
  return p.join(
    (programData == null || programData.isEmpty)
        ? r'C:\ProgramData'
        : programData,
    'omnyserver',
  );
}

/// The data root: the directory holding *everything* this installation keeps —
/// credentials and identity, plus (for a Hub) the fleet data underneath it.
///
/// Resolves `--data-dir` when given, else the machine-wide root under
/// [systemScope], else [OmnyServerHome.resolve] (`~/.omnyserver`). Returns
/// `null` only for `--ephemeral`, which asks for no persistence at all.
///
/// Always resolving is deliberate: a Hub with no data directory silently
/// forgets the fleet, the audit trail and every credential `grant add` issued —
/// on every restart. Opting into that should be explicit, hence `--ephemeral`.
String? resolveDataDir(ArgResults args, {bool systemScope = false}) {
  final raw = (args['data-dir'] as String?)?.trim();
  final explicit = raw != null && raw.isNotEmpty;
  final ephemeral = args['ephemeral'] as bool;

  if (ephemeral) {
    if (explicit) {
      throw CliError(
        'use either --data-dir or --ephemeral, not both '
        '(--ephemeral means "persist nothing")',
      );
    }
    return null;
  }
  if (explicit) return p.normalize(p.absolute(raw));
  return systemScope ? systemDataDir() : OmnyServerHome.resolve();
}

/// The Hub's persistence directory inside the data root: the fleet data
/// (nodes, audit, metrics, desired state, issued grants) lives under `hub/`,
/// alongside — not mixed into — the credentials and identity at the root.
String hubDataDir(String root) => p.join(root, 'hub');

/// The directory `hub start` persists the fleet in.
///
/// Note the deliberate asymmetry with [resolveDataDir]: an explicit
/// `--data-dir` on `hub start` names *the Hub's own directory* — as it always
/// has — and is used verbatim. Only the default is composed, as `<root>/hub`.
///
/// This is what lets `service install` and `hub start` agree without either
/// one double-appending: `service install` resolves the root and bakes
/// `--data-dir <root>/hub` into the command, and `hub start` then takes that
/// path as given.
///
/// Returns `null` for `--ephemeral`.
String? resolveHubDataDir(ArgResults args) {
  final raw = (args['data-dir'] as String?)?.trim();
  final explicit = raw != null && raw.isNotEmpty;

  if (args['ephemeral'] as bool) {
    if (explicit) {
      throw CliError(
        'use either --data-dir or --ephemeral, not both '
        '(--ephemeral means "persist nothing")',
      );
    }
    return null;
  }
  if (explicit) return p.normalize(p.absolute(raw));
  return hubDataDir(OmnyServerHome.resolve());
}

// ---------------------------------------------------------------------------
// Command-line reconstruction.
//
// `service install` bakes an `omnyserver <role> start …` command line into the
// OS service definition, so every emitted value must be independent of the
// directory the operator happened to install from.
// ---------------------------------------------------------------------------

/// Appends `--name value` to [out] when [value] is non-empty.
void emitOption(List<String> out, String name, Object? value) {
  if (value == null) return;
  final s = value.toString();
  if (s.isEmpty) return;
  out
    ..add('--$name')
    ..add(s);
}

/// Like [emitOption], but absolutized — so the baked-in service command finds
/// the file regardless of the service's working directory.
///
/// Only for *filesystem* paths. `--node-path` and `--shell-path` look like
/// paths but are HTTP mount points: absolutizing them would bake
/// `--node-path /home/you/omnyserver/node` into the unit and the Hub would
/// serve nodes on a nonsense route.
void emitPathOption(List<String> out, String name, Object? value) {
  if (value == null) return;
  final s = value.toString();
  if (s.isEmpty) return;
  out
    ..add('--$name')
    ..add(p.normalize(p.absolute(s)));
}

/// Appends `--name value` once per entry of a multi-option.
void emitMultiOption(List<String> out, String name, List<String> values) {
  for (final v in values) {
    out
      ..add('--$name')
      ..add(v);
  }
}

/// A non-negatable flag: emitted when set, absent otherwise.
void emitFlag(List<String> out, String name, bool value) {
  if (value) out.add('--$name');
}

/// A *negatable* flag, emitted explicitly in both directions.
///
/// Always explicit, because the baked-in command outlives the default that
/// produced it: `--ship-logs` defaults to true today, and a service installed
/// with `--no-ship-logs` must keep shipping nothing even if that default flips.
void emitNegatableFlag(List<String> out, String name, bool value) =>
    out.add(value ? '--$name' : '--no-$name');
