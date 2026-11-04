import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart'
    show ArchiveFile, InputFileStream, OutputFileStream, ZipDecoder;
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
///     strip: "0"       # leading path components to drop, as tar's
/// ```
///
/// Other params: `auth` (`none`, `metadata` — the default for `gs://` — or
/// `bearer-file:/path`), `verify: none` to install without a digest, and
/// `rollback: none` to keep a new version even when what runs it fails.
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
        // Only when there is something to add: the planner already says "is
        // 1.1.0, should be 1.2.0", and appends this to it.
        ? '$declared was rolled back at ${rolledBack['at']}'
        : '';

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
    // Trimmed as the install trims it: a digest with a trailing newline (a
    // YAML `|` block) must not read as a different build on every plan — that
    // would reinstall it, and restart the service, on every apply.
    final sha = params['sha256']?.trim().toLowerCase();
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
      // By version *and* digest: a rebuilt 1.0.141 sits beside the original
      // under another name, and the one to go back to is the one that ran.
      final dir = _findInstalled(root, previous, before.fingerprint);
      if (dir == null) {
        return _failed(resource, '$previous is no longer on disk');
      }
      // What is being rolled back from — read before the swap, so the record
      // names the exact build that failed, and an apply of that same build is
      // refused rather than retried into the same outage.
      final failed = _currentMarker(root);
      _swapCurrent(root, dir);
      if (failed != null) {
        File(p.join(root, rolledBackFile)).writeAsStringSync(
          jsonEncode({
            'version': failed.version,
            'sha256': failed.sha256,
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
    final sha = declaredSha == null || declaredSha.isEmpty ? null : declaredSha;

    // Nothing is fetched into a root whose `current` is not ours: a real
    // directory there, or a link to something that is not a release, is left
    // exactly as it is — and found out before the download, not after it.
    final currentPath = p.join(root, 'current');
    final currentKind = FileSystemEntity.typeSync(
      currentPath,
      followLinks: false,
    );
    if (currentKind != FileSystemEntityType.notFound) {
      if (currentKind != FileSystemEntityType.link) {
        return _failed(
          resource,
          '$currentPath exists and is not a symlink — not touching it',
        );
      }
      if (_currentMarker(root) == null) {
        return _failed(
          resource,
          '$currentPath points at something that is not a release — not '
          'touching it',
        );
      }
    }

    // The build this node has already rolled back from is not deployed again
    // by itself: an apply on a timer would otherwise reinstall it, fail the
    // same health check and roll back, over and over — an outage on every
    // interval. A different build (a new version, or a rebuild with a new
    // digest) goes ahead.
    final rolledBackFrom = _readJson(p.join(root, rolledBackFile));
    if (rolledBackFrom != null &&
        rolledBackFrom['version'] == version &&
        (sha == null || rolledBackFrom['sha256'] == sha)) {
      return _failed(
        resource,
        'not retried: $version was rolled back at ${rolledBackFrom['at']} — '
        'deploy a fixed build, or delete ${p.join(root, rolledBackFile)} to '
        'try this one again',
      );
    }

    Directory(p.join(root, 'releases')).createSync(recursive: true);
    final previousDir = _currentDir(root);
    final previous = current.isPresent ? current.version : null;

    // Already unpacked — a downgrade, or the previous version coming back. The
    // marker's digest says whether it is the *same* bundle: a rebuilt 1.0.141
    // is not the 1.0.141 on disk.
    var dir = _findInstalled(root, version, sha);
    if (dir == null) {
      dir = await _download(
        resource,
        root: root,
        url: url,
        version: version,
        declaredSha: sha,
        verify: verify,
        context: context,
      );
    } else {
      context.log('$version is already on disk — reusing it');
    }

    _swapCurrent(root, dir);
    final rolledBack = File(p.join(root, rolledBackFile));
    if (rolledBack.existsSync()) rolledBack.deleteSync();
    _prune(root, keep: keep, keepDirs: {dir, ?previousDir}, log: context.log);

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

  /// Downloads, verifies and unpacks a build, returning the name of the
  /// directory under `releases/` it now lives in.
  ///
  /// Never the directory `current` points at. A rebuilt 1.0.141 goes beside
  /// the original (`1.0.141~<digest>`) rather than over it: replacing it in
  /// place would leave `current` pointing at nothing for a moment, and would
  /// destroy the very build a rollback goes back to.
  Future<String> _download(
    ResolvedResource resource, {
    required String root,
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
      final strip = int.tryParse(resource.resource.params['strip'] ?? '0');
      if (strip == null || strip < 0) {
        throw ArgumentError(
          'strip "${resource.resource.params['strip']}" — want a number of '
          'leading path components, like tar --strip-components',
        );
      }
      final count = await _extract(
        zip.path,
        staging.path,
        strip: strip,
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

      final name = _freeName(root, version, sha);
      staging.renameSync(p.join(root, 'releases', name));
      return name;
    } finally {
      if (zip.existsSync()) zip.deleteSync();
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  }

  /// Unpacks [zipPath] into [outDir], returning how many files it wrote.
  ///
  /// [strip] drops that many leading path components from every entry — `1`
  /// unpacks `myapp-1.2.3/bin/app` as `bin/app` — and skips an entry that has
  /// no more than that. Explicit, never guessed: a bundle that happens to hold
  /// only `bin/` must keep its `bin/`, or every `exec:` pointing into it breaks.
  Future<int> _extract(
    String zipPath,
    String outDir, {
    required int strip,
    required List<RegExp> executables,
  }) async {
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final byMode = <String, List<String>>{};
      var count = 0;
      final base = p.normalize(outDir);

      // Every entry is checked before anything is written, because the checks
      // are about the archive as a whole. Path text alone cannot catch an
      // escape built out of the archive's own symlinks: `x/y/z -> ..`, then
      // `x/y/z/w -> ../..`, then a file under `x/y/z/w/…` — each is inside the
      // release on paper, and together they write outside it once the links
      // exist on disk. So nothing may pass *through* a symlink the archive
      // declares, and the links themselves are made last, once every file is
      // already where it belongs.
      final entries = <({ArchiveFile file, String name, String path})>[];
      final links = <String>{};
      for (final file in archive.files) {
        var name = p.posix.normalize(file.name.replaceAll('\\', '/'));
        if (strip > 0) {
          final parts = name.split('/').where((s) => s.isNotEmpty).toList();
          if (parts.length <= strip) continue;
          name = parts.sublist(strip).join('/');
        }
        if (name.isEmpty || name == '/' || name == '.') continue;

        final outPath = p.normalize(p.join(outDir, name));
        // `./` — the archive's own root, which is outDir itself.
        if (outPath == base) continue;
        if (p.isAbsolute(name) || !p.isWithin(base, outPath)) {
          throw StateError('zip entry "${file.name}" escapes the release');
        }
        if (file.isSymbolicLink) {
          final target = file.symbolicLink!;
          final resolved = p.normalize(p.join(p.dirname(outPath), target));
          if (p.isAbsolute(target) || !p.isWithin(base, resolved)) {
            throw StateError(
              'zip entry "${file.name}" links outside the release ($target)',
            );
          }
          links.add(name);
        }
        entries.add((file: file, name: name, path: outPath));
      }
      for (final e in entries) {
        final parts = e.name.split('/');
        for (var i = 1; i < parts.length; i++) {
          final ancestor = parts.sublist(0, i).join('/');
          if (links.contains(ancestor)) {
            throw StateError(
              'zip entry "${e.file.name}" is inside the symlink "$ancestor" — '
              'refused, since writing through it could leave the release',
            );
          }
        }
      }

      for (final e in entries) {
        if (e.file.isSymbolicLink) continue;
        if (!e.file.isFile) {
          Directory(e.path).createSync(recursive: true);
          continue;
        }
        final outPath = e.path;
        final name = e.name;
        final file = e.file;

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

      // Last: the links, now that nothing else will be written beneath them.
      for (final e in entries) {
        if (!e.file.isSymbolicLink) continue;
        Directory(p.dirname(e.path)).createSync(recursive: true);
        Link(e.path).createSync(e.file.symbolicLink!);
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

  /// Points `current` at `releases/<dir>`, atomically.
  void _swapCurrent(String root, String dir) {
    final staged = Link(p.join(root, '.current-${_nonce()}'));
    // Relative, so the whole root can be moved or mounted elsewhere and still
    // make sense.
    staged.createSync(p.join('releases', dir));
    try {
      staged.renameSync(p.join(root, 'current'));
    } on Object {
      if (staged.existsSync()) staged.deleteSync();
      rethrow;
    }
  }

  /// The directory under `releases/` holding [version] — with digest [sha],
  /// when one is given — or `null`.
  ///
  /// Looked up by marker, not by name: a rebuild lives beside the original
  /// under a suffixed name.
  String? _findInstalled(String root, String version, String? sha) {
    final dir = Directory(p.join(root, 'releases'));
    if (!dir.existsSync()) return null;
    // The plain name first, so an unverified install reuses the usual place.
    final names = [
      version,
      for (final e in dir.listSync(followLinks: false))
        if (e is Directory && p.basename(e.path) != version) p.basename(e.path),
    ];
    for (final name in names) {
      final marker = _readMarker(p.join(dir.path, name));
      if (marker == null || marker.version != version) continue;
      if (sha == null || marker.sha256 == sha) return name;
    }
    return null;
  }

  /// A name under `releases/` for a new build of [version]: the version
  /// itself when free, the version and the start of its digest otherwise.
  String _freeName(String root, String version, String sha) {
    bool free(String name) =>
        FileSystemEntity.typeSync(
          p.join(root, 'releases', name),
          followLinks: false,
        ) ==
        FileSystemEntityType.notFound;
    if (free(version)) return version;
    final suffixed = '$version~${sha.substring(0, 12)}';
    if (free(suffixed)) return suffixed;
    // The same digest under the suffixed name without a marker: a leftover
    // of an interrupted install, never what `current` points at (that one
    // has a marker, or it would have been reused).
    final leftover = p.join(root, 'releases', suffixed);
    if (_currentDir(root) != suffixed) {
      Directory(leftover).deleteSync(recursive: true);
      return suffixed;
    }
    return '$suffixed~${_nonce()}';
  }

  /// The directory name under `releases/` that `current` points at.
  String? _currentDir(String root) {
    final current = p.join(root, 'current');
    if (FileSystemEntity.typeSync(current, followLinks: false) !=
        FileSystemEntityType.link) {
      return null;
    }
    return p.basename(p.normalize(Link(current).targetSync()));
  }

  /// The marker of the release `current` points at.
  _Marker? _currentMarker(String root) {
    final dir = _currentDir(root);
    return dir == null ? null : _readMarker(p.join(root, 'releases', dir));
  }

  /// Deletes old builds beyond [keep], never one in [keepDirs].
  void _prune(
    String root, {
    required int keep,
    required Set<String> keepDirs,
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
      if (keepDirs.contains(p.basename(r.dir.path)) || kept < limit) {
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
