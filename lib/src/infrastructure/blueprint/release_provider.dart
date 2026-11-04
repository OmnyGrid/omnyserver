import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../domain/blueprint/resolved_blueprint.dart';
import '../../domain/blueprint/resource.dart';
import '../../domain/blueprint/resource_change.dart';
import '../../domain/blueprint/resource_provider.dart';
import '../../domain/blueprint/resource_state.dart';
import '../../domain/formula/formula_context.dart';
import '../../domain/formula/formula_status.dart';
import 'release_fetcher.dart';

/// Serves `release:<name>` resources: a versioned application bundle,
/// downloaded, verified, unpacked beside the versions before it, and made
/// current by swapping one symlink.
///
/// ```yaml
/// - type: release
///   name: nfeflash_api
///   ensure: present
///   params:
///     version: "1.0.141"
///     url: "gs://nfeflash_releases/nfeflash_api/nfeflash_api-1.0.141-linux-x64.zip"
///     sha256: "…"
///     root: /opt/nfeflash
///     keep: "3"
///     executables: "api_server,nfeflash_cli,bin/*"
/// ```
///
/// On disk, under `root`:
///
/// ```text
/// releases/1.0.140/          the previous version, kept for a rollback
/// releases/1.0.141/          this one, with .omnyserver-release.json inside
/// current -> releases/1.0.141
/// ```
///
/// The guarantees, which are the reason this is a provider and not a script:
///
/// * **A half-installed release is never current.** The bundle is downloaded
///   and unpacked under a temporary name, renamed into `releases/` only when
///   complete, and `current` is replaced with a single `rename(2)` — a process
///   started at any instant sees the old version or the new one, never a mix.
/// * **What runs is what was declared.** `sha256` is checked over the bytes as
///   they were written; a mismatch fails the apply and leaves nothing behind.
///   Skipping the check takes an explicit `verify: none`.
/// * **The machine is the truth.** [read] looks at `current` and the marker in
///   the directory it points to; it never trusts a record of what was applied.
/// * **Nothing escapes `root`.** A zip entry naming `../../etc/passwd` fails the
///   apply, and `root` itself must sit under one of [allowedRoots].
///
/// Linux and macOS. On Windows a symlink needs a privilege a service rarely
/// has, so the type reports `unknown` there rather than half-working.
class ReleaseProvider
    implements ResourceProvider, ConvergenceJudge, RevertibleProvider {
  /// Directories a release `root` may be inside. `null` means anywhere — for
  /// embedding and tests; the CLI always passes the node's `--allow-root`s.
  final List<String>? allowedRoots;

  /// Downloads bundles.
  final ReleaseFetcher fetcher;

  /// Runs `chmod`. A seam so a test can see what was made executable.
  final Future<ProcessResult> Function(String executable, List<String> args)
  runProcess;

  /// Whether this platform can hold a release at all.
  final bool supported;

  /// Creates a release provider.
  ReleaseProvider({
    this.allowedRoots,
    ReleaseFetcher? fetcher,
    Future<ProcessResult> Function(String executable, List<String> args)?
    runProcess,
    bool? supported,
  }) : fetcher = fetcher ?? ReleaseFetcher(),
       runProcess = runProcess ?? Process.run,
       supported = supported ?? !Platform.isWindows;

  /// The marker each installed version carries.
  static const String markerFile = '.omnyserver-release.json';

  /// Remembers the last version rolled back from, so a plan can say so.
  static const String rolledBackFile = '.omnyserver-rolled-back.json';

  /// A version is a directory name, so it may not be a path.
  static final RegExp _validVersion = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$');

  @override
  String get type => 'release';

  @override
  Set<Ensure> get supportedEnsure => const {
    Ensure.present,
    Ensure.installed,
    Ensure.absent,
  };

  /// Where [resource] lives.
  String rootOf(ResolvedResource resource) {
    final declared = resource.resource.params['root'];
    final root = p.normalize(
      p.absolute(declared ?? p.join('/opt', resource.id.name)),
    );
    if (declared != null && !p.isAbsolute(declared)) {
      throw ArgumentError('release root "$declared" must be an absolute path');
    }
    if (p.split(root).length < 2 || root == p.rootPrefix(root)) {
      throw ArgumentError('release root "$root" is the filesystem root');
    }
    final allowed = allowedRoots;
    if (allowed != null &&
        !allowed.any((a) {
          final base = p.normalize(p.absolute(a));
          return root == base || p.isWithin(base, root);
        })) {
      throw ArgumentError(
        'release root "$root" is outside what this node allows '
        '(${allowed.isEmpty ? 'nothing — start it with --allow-root' : allowed.join(', ')})',
      );
    }
    return root;
  }

  @override
  Future<ResourceState> read(
    ResolvedResource resource,
    FormulaContext context,
  ) async {
    if (!supported) {
      return ResourceState.unknown(
        resource.id,
        context.now(),
        message: 'release resources are not supported on this platform yet',
      );
    }
    final root = rootOf(resource);
    final current = p.join(root, 'current');
    final kind = FileSystemEntity.typeSync(current, followLinks: false);

    if (kind == FileSystemEntityType.notFound) {
      return ResourceState(
        id: resource.id,
        status: FormulaStatus.absent,
        checkedAt: context.now(),
        message: 'no current release under $root',
      );
    }
    if (kind != FileSystemEntityType.link) {
      // Something put a real directory where the link goes. Not ours to
      // replace on a guess: unknown, and the apply will not touch it.
      return ResourceState.unknown(
        resource.id,
        context.now(),
        message: '$current exists and is not a symlink',
      );
    }

    final target = p.normalize(p.join(root, Link(current).targetSync()));
    final marker = _readMarker(target);
    if (marker == null) {
      return ResourceState.unknown(
        resource.id,
        context.now(),
        message: '$current points at $target, which holds no release marker',
      );
    }

    final declared = resource.resource.version;
    final rolledBack = _readJson(p.join(root, rolledBackFile));
    final note =
        rolledBack != null &&
            declared != null &&
            rolledBack['version'] == declared &&
            marker.version != declared
        ? '$declared was rolled back at ${rolledBack['at']}'
              '${rolledBack['reason'] is String ? ': ${rolledBack['reason']}' : ''}'
        : 'current is ${marker.version}';

    return ResourceState(
      id: resource.id,
      status: FormulaStatus.installed,
      version: marker.version,
      fingerprint: marker.sha256,
      message: note,
      checkedAt: context.now(),
    );
  }

  @override
  bool satisfies(ResolvedResource resource, ResourceState state) {
    if (state.status == FormulaStatus.unknown) return false;
    if (resource.ensure == Ensure.absent) {
      return state.status == FormulaStatus.absent;
    }
    if (!state.isPresent) return false;
    final params = resource.resource.params;
    if (params['version'] != state.version) return false;
    final sha = params['sha256']?.toLowerCase();
    // A declared digest is part of what "this version" means: the same version
    // number rebuilt is a different release, and should be redeployed.
    return sha == null || sha.isEmpty || sha == state.fingerprint;
  }

  @override
  Future<ResourceChange> apply(
    ResolvedResource resource,
    ResourceState current,
    FormulaContext context,
  ) async {
    if (!supported) {
      return _failed(resource, 'not supported on this platform yet');
    }
    try {
      final root = rootOf(resource);
      return resource.ensure == Ensure.absent
          ? _remove(resource, root, context)
          : await _install(resource, current, root, context);
    } on Object catch (e) {
      return _failed(resource, '$e');
    }
  }

  @override
  Future<ResourceChange> revert(
    ResolvedResource resource,
    ResourceState before,
    FormulaContext context,
  ) async {
    final previous = before.version;
    if (!before.isPresent || previous == null) {
      return _failed(
        resource,
        'nothing to roll back to — there was no release here before',
      );
    }
    try {
      final root = rootOf(resource);
      final dir = p.join(root, 'releases', previous);
      if (_readMarker(dir) == null) {
        return _failed(resource, '$previous is no longer on disk');
      }
      _swapCurrent(root, previous);
      final declared = resource.resource.version;
      if (declared != null) {
        File(p.join(root, rolledBackFile)).writeAsStringSync(
          jsonEncode({
            'version': declared,
            'to': previous,
            'at': context.now().toUtc().toIso8601String(),
          }),
        );
      }
      context.log('rolled back: current is $previous again');
      return ResourceChange(
        id: resource.id,
        kind: ChangeKind.update,
        reason: 'back on $previous',
        origin: resource.origin,
      );
    } on Object catch (e) {
      return _failed(resource, '$e');
    }
  }

  // ---------------------------------------------------------------------------

  Future<ResourceChange> _install(
    ResolvedResource resource,
    ResourceState current,
    String root,
    FormulaContext context,
  ) async {
    final params = resource.resource.params;
    final version = params['version'];
    if (version == null || version.isEmpty) {
      return _failed(resource, 'a release needs a version');
    }
    if (!_validVersion.hasMatch(version)) {
      return _failed(resource, 'version "$version" is not a valid name');
    }
    final url = params['url'];
    if (url == null || url.isEmpty) {
      return _failed(resource, 'a release needs a url');
    }
    final declaredSha = params['sha256']?.trim().toLowerCase();
    final verify = params['verify'] ?? 'sha256';
    if (verify != 'none' && (declaredSha == null || declaredSha.isEmpty)) {
      return _failed(
        resource,
        'a release needs a sha256 — or an explicit `verify: none`',
      );
    }
    if (declaredSha != null &&
        declaredSha.isNotEmpty &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(declaredSha)) {
      return _failed(resource, 'sha256 "$declaredSha" is not a SHA-256 digest');
    }
    final keep = int.tryParse(params['keep'] ?? '3') ?? 3;

    Directory(p.join(root, 'releases')).createSync(recursive: true);
    final target = p.join(root, 'releases', version);
    final existing = _readMarker(target);
    final previous = current.isPresent ? current.version : null;

    // Already unpacked — a downgrade, or the previous version coming back. The
    // marker's digest says whether it is the *same* bundle: a rebuilt 1.0.141
    // is not the 1.0.141 on disk.
    final reusable =
        existing != null &&
        existing.version == version &&
        (declaredSha == null ||
            declaredSha.isEmpty ||
            existing.sha256 == declaredSha);

    if (!reusable) {
      await _download(
        resource,
        root: root,
        target: target,
        url: url,
        version: version,
        declaredSha: declaredSha,
        verify: verify,
        context: context,
      );
    } else {
      context.log('$version is already on disk — reusing it');
    }

    _swapCurrent(root, version);
    final rolledBack = File(p.join(root, rolledBackFile));
    if (rolledBack.existsSync()) rolledBack.deleteSync();
    _prune(
      root,
      keep: keep,
      keepVersions: {version, ?previous},
      log: context.log,
    );

    context.log('current is now $version');
    return ResourceChange(
      id: resource.id,
      kind: previous == null ? ChangeKind.create : ChangeKind.update,
      reason: previous == null
          ? 'installed $version'
          : previous == version
          ? 'reinstalled $version'
          : 'installed $version (was $previous)',
      origin: resource.origin,
    );
  }

  Future<void> _download(
    ResolvedResource resource, {
    required String root,
    required String target,
    required String url,
    required String version,
    required String? declaredSha,
    required String verify,
    required FormulaContext context,
  }) async {
    final tag = '${version}_${_nonce()}';
    final zip = File(p.join(root, '.tmp-$tag.zip'));
    final staging = Directory(p.join(root, '.tmp-$tag'));
    try {
      context.log('fetching $url');
      final sha = await fetcher.fetch(
        url,
        zip,
        auth: resource.resource.params['auth'],
        log: context.log,
      );
      if (verify != 'none' && sha != declaredSha) {
        throw StateError(
          'sha256 mismatch for $url: expected $declaredSha, got $sha — '
          'nothing was installed',
        );
      }
      context.log('sha256 $sha${verify == 'none' ? ' (not verified)' : ' ok'}');

      staging.createSync(recursive: true);
      final count = await _extract(
        zip.path,
        staging.path,
        executables: _patterns(resource.resource.params['executables']),
      );
      context.log('unpacked $count files');

      File(p.join(staging.path, markerFile)).writeAsStringSync(
        jsonEncode({
          'name': resource.id.name,
          'version': version,
          'sha256': sha,
          'url': url,
          'installedAt': context.now().toUtc().toIso8601String(),
        }),
      );

      // A directory already at the target is a broken or different build of
      // the same version: replaced, but only after the new one is complete.
      final dest = Directory(target);
      if (dest.existsSync()) dest.deleteSync(recursive: true);
      staging.renameSync(target);
    } finally {
      if (zip.existsSync()) zip.deleteSync();
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  }

  /// Unpacks [zipPath] into [outDir], returning how many files it wrote.
  Future<int> _extract(
    String zipPath,
    String outDir, {
    required List<RegExp> executables,
  }) async {
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final names = [
        for (final f in archive.files) f.name.replaceAll('\\', '/'),
      ];
      final strip = _commonRoot(names);
      final byMode = <String, List<String>>{};
      var count = 0;

      for (final file in archive.files) {
        var name = file.name.replaceAll('\\', '/');
        if (strip != null) name = name.substring(strip.length);
        if (name.isEmpty || name == '/') continue;

        final outPath = p.normalize(p.join(outDir, name));
        // `./` — the archive's own root, which is outDir itself.
        if (outPath == p.normalize(outDir)) continue;
        if (!p.isWithin(outDir, outPath)) {
          throw StateError('zip entry "${file.name}" escapes the release');
        }

        if (file.isSymbolicLink) {
          final link = file.symbolicLink!;
          final resolved = p.normalize(p.join(p.dirname(outPath), link));
          if (p.isAbsolute(link) || !p.isWithin(outDir, resolved)) {
            throw StateError(
              'zip entry "${file.name}" links outside the release ($link)',
            );
          }
          Directory(p.dirname(outPath)).createSync(recursive: true);
          Link(outPath).createSync(link);
          continue;
        }
        if (!file.isFile) {
          Directory(outPath).createSync(recursive: true);
          continue;
        }

        Directory(p.dirname(outPath)).createSync(recursive: true);
        final output = OutputFileStream(outPath);
        try {
          file.writeContent(output);
        } finally {
          output.closeSync();
        }
        count++;

        final relative = p.posix.normalize(name);
        var mode = file.unixPermissions;
        if (mode == 0) mode = 0x1a4; // 0644 — a zip made where there are none.
        if (executables.any((e) => e.hasMatch(relative))) {
          mode |= 0x49; // +x for owner, group and others.
        }
        if (mode != 0x1a4) {
          (byMode[mode.toRadixString(8)] ??= []).add(outPath);
        }
      }

      for (final entry in byMode.entries) {
        // Batched: one chmod per mode and a few hundred paths, not one process
        // per file of a bundle that has thousands.
        for (var i = 0; i < entry.value.length; i += 200) {
          final batch = entry.value.sublist(
            i,
            min(i + 200, entry.value.length),
          );
          final result = await runProcess('chmod', [entry.key, ...batch]);
          if (result.exitCode != 0) {
            throw StateError('chmod ${entry.key} failed: ${result.stderr}');
          }
        }
      }
      return count;
    } finally {
      input.closeSync();
    }
  }

  /// The single top-level directory every entry shares, if there is one.
  ///
  /// A bundle zipped as `myapp-1.2.3/bin/…` unpacks as `bin/…`, so `current`
  /// always points at the directory the executables are in — whichever way the
  /// zip was made.
  static String? _commonRoot(List<String> names) {
    String? root;
    for (final name in names) {
      final slash = name.indexOf('/');
      if (slash <= 0) return null;
      final first = name.substring(0, slash + 1);
      root ??= first;
      if (first != root) return null;
    }
    return root;
  }

  /// `api_server,bin/*` as patterns over a release-relative path.
  ///
  /// `*` matches within one path segment, `**` across them.
  static List<RegExp> _patterns(String? spec) {
    if (spec == null || spec.trim().isEmpty) return const [];
    return [
      for (final raw in spec.split(','))
        if (raw.trim().isNotEmpty) _glob(raw.trim()),
    ];
  }

  static RegExp _glob(String pattern) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          buffer.write('.*');
          i++;
        } else {
          buffer.write('[^/]*');
        }
      } else if (c == '?') {
        buffer.write('[^/]');
      } else {
        buffer.write(RegExp.escape(c));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }

  /// Points `current` at `releases/<version>`, atomically.
  void _swapCurrent(String root, String version) {
    final staged = Link(p.join(root, '.current-${_nonce()}'));
    // Relative, so the whole root can be moved or mounted elsewhere and still
    // make sense.
    staged.createSync(p.join('releases', version));
    try {
      staged.renameSync(p.join(root, 'current'));
    } on Object {
      if (staged.existsSync()) staged.deleteSync();
      rethrow;
    }
  }

  /// Deletes old versions beyond [keep], never one in [keepVersions].
  void _prune(
    String root, {
    required int keep,
    required Set<String> keepVersions,
    required void Function(String) log,
  }) {
    final dir = Directory(p.join(root, 'releases'));
    final installed = <({String version, String at, Directory dir})>[];
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final marker = _readMarker(entry.path);
      if (marker == null) continue;
      installed.add((
        version: marker.version,
        at: marker.installedAt,
        dir: entry,
      ));
    }
    installed.sort((a, b) => b.at.compareTo(a.at));
    // At least two: the one running, and the one a rollback goes back to.
    final limit = max(keep, 2);
    var kept = 0;
    for (final r in installed) {
      if (keepVersions.contains(r.version) || kept < limit) {
        kept++;
        continue;
      }
      r.dir.deleteSync(recursive: true);
      log('removed old release ${r.version}');
    }
  }

  ResourceChange _remove(
    ResolvedResource resource,
    String root,
    FormulaContext context,
  ) {
    final current = Link(p.join(root, 'current'));
    if (FileSystemEntity.typeSync(current.path, followLinks: false) ==
        FileSystemEntityType.link) {
      current.deleteSync();
    }
    // Only what carries this release's marker: a root shared with anything
    // else keeps everything else.
    final releases = Directory(p.join(root, 'releases'));
    if (releases.existsSync()) {
      for (final entry in releases.listSync(followLinks: false)) {
        if (entry is Directory && _readMarker(entry.path) != null) {
          entry.deleteSync(recursive: true);
        }
      }
      if (releases.listSync().isEmpty) releases.deleteSync();
    }
    final rolledBack = File(p.join(root, rolledBackFile));
    if (rolledBack.existsSync()) rolledBack.deleteSync();
    final rootDir = Directory(root);
    if (rootDir.existsSync() && rootDir.listSync().isEmpty) {
      rootDir.deleteSync();
    }
    context.log('removed every release under $root');
    return ResourceChange(
      id: resource.id,
      kind: ChangeKind.remove,
      reason: 'removed',
      origin: resource.origin,
    );
  }

  static _Marker? _readMarker(String dir) {
    final json = _readJson(p.join(dir, markerFile));
    if (json == null) return null;
    final version = json['version'];
    final sha = json['sha256'];
    if (version is! String || sha is! String) return null;
    return _Marker(
      version: version,
      sha256: sha,
      installedAt: json['installedAt'] is String
          ? json['installedAt'] as String
          : '',
    );
  }

  static Map<String, dynamic>? _readJson(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync());
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      return null;
    }
  }

  static final Random _random = Random();

  static String _nonce() =>
      _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');

  ResourceChange _failed(ResolvedResource resource, String reason) =>
      ResourceChange(
        id: resource.id,
        kind: ChangeKind.failed,
        reason: reason,
        origin: resource.origin,
      );
}

class _Marker {
  _Marker({
    required this.version,
    required this.sha256,
    required this.installedAt,
  });

  final String version;
  final String sha256;
  final String installedAt;
}
