@TestOn('vm')
library;

import 'dart:io';

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

void main() {
  group('ReleaseFetcher.resolve', () {
    final fetcher = ReleaseFetcher(
      storageBase: Uri.parse('https://storage.example/'),
    );

    test('https and http are fetched as they are', () {
      expect(
        fetcher.resolve('https://cdn.example/app.zip').toString(),
        'https://cdn.example/app.zip',
      );
      expect(
        fetcher.resolve('http://10.0.0.1:8090/app.zip').toString(),
        'http://10.0.0.1:8090/app.zip',
      );
    });

    test('gs:// becomes the JSON API, the object one encoded segment', () {
      expect(
        fetcher
            .resolve('gs://nfeflash_releases/nfeflash_api/app-1.0.0.zip')
            .toString(),
        'https://storage.example/download/storage/v1/b/nfeflash_releases/o/'
        'nfeflash_api%2Fapp-1.0.0.zip?alt=media',
      );
    });

    test('a gs:// with no object, or another scheme, is refused', () {
      expect(() => fetcher.resolve('gs://bucket-only'), throwsArgumentError);
      expect(() => fetcher.resolve('ftp://x/y.zip'), throwsArgumentError);
      expect(() => fetcher.resolve('/local/file.zip'), throwsArgumentError);
    });

    test('gs:// defaults to the metadata token, anything else to none', () {
      expect(ReleaseFetcher.defaultAuth('gs://b/o.zip'), 'metadata');
      expect(ReleaseFetcher.defaultAuth('https://x/o.zip'), 'none');
    });
  });

  group('ReleaseFetcher.fetch', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('omnyserver-fetch'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('off a cloud VM, auth metadata says why it cannot work', () async {
      // Nothing listens on this port: the lookup fails the way it does on a
      // laptop, where there is no metadata server at all.
      final fetcher = ReleaseFetcher(
        metadataBase: Uri.parse('http://127.0.0.1:9/'),
        connectTimeout: const Duration(seconds: 2),
      );
      await expectLater(
        fetcher.fetch('gs://b/o.zip', File('${dir.path}/o.zip')),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('only works on a Google Cloud VM'),
          ),
        ),
      );
    });

    test('an empty or missing bearer file is refused', () async {
      final empty = File('${dir.path}/empty')..writeAsStringSync('  \n');
      final fetcher = ReleaseFetcher();
      await expectLater(
        fetcher.fetch(
          'https://x.invalid/o.zip',
          File('${dir.path}/o.zip'),
          auth: 'bearer-file:${empty.path}',
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        fetcher.fetch(
          'https://x.invalid/o.zip',
          File('${dir.path}/o.zip'),
          auth: 'bearer-file:${dir.path}/nope',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
