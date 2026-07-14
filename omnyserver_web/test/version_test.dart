@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver_web/version.dart'
    show omnyServerWebVersion, versionLabel;
import 'package:test/test.dart';

void main() {
  group('omnyServerWebVersion', () {
    test('matches the version declared in pubspec.yaml', () {
      final pubspec = File('pubspec.yaml');
      expect(
        pubspec.existsSync(),
        isTrue,
        reason: 'test must run from the omnyserver_web package root',
      );
      final match = RegExp(
        r'''^version:\s*['"]?([^'"\s]+)''',
        multiLine: true,
      ).firstMatch(pubspec.readAsStringSync());
      expect(
        match,
        isNotNull,
        reason: 'no version: line found in pubspec.yaml',
      );
      expect(
        omnyServerWebVersion,
        equals(match!.group(1)),
        reason:
            'omnyServerWebVersion (lib/version.dart) is out of sync with '
            'pubspec.yaml — update the constant when bumping the dashboard '
            'version',
      );
    });
  });

  group('versionLabel', () {
    test('names the dashboard build and the server it was built against', () {
      expect(versionLabel, contains('Dashboard v$omnyServerWebVersion'));
      // The server half is resolved from the omnyserver package (path-overridden
      // to this repo in CI), so assert the shape, not a pinned number.
      expect(versionLabel, matches(RegExp(r'OmnyServer v\d+\.\d+\.\d+')));
    });
  });
}
