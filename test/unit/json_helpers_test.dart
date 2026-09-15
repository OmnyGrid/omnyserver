@TestOn('vm')
library;

import 'package:omnyserver/omnyserver.dart';
import 'package:test/test.dart';

/// Every decoder in the package reads its fields through [Json], and the reason
/// it exists is the failure case: a malformed frame must come back as a
/// [ProtocolException] naming the field, not as a `TypeError` from somewhere
/// three layers down.
void main() {
  /// Asserts [read] rejects [json] with a message naming [field].
  void rejects(
    String description,
    Object? Function(Map<String, dynamic>) read,
    Map<String, dynamic> json,
    String field,
  ) {
    test(description, () {
      expect(
        () => read(json),
        throwsA(
          isA<ProtocolException>()
              .having((e) => e.message, 'message', contains(field))
              .having((e) => e.code, 'code', ErrorCodes.protocolError),
        ),
      );
    });
  }

  group('asObject', () {
    test('casts a JSON object', () {
      expect(Json.asObject({'a': 1}), {'a': 1});
    });

    test('names what was expected when it is not an object', () {
      expect(
        () => Json.asObject('nope', 'heartbeat'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('heartbeat'),
          ),
        ),
      );
    });
  });

  group('strings', () {
    test('required and optional read through', () {
      expect(Json.requireString({'a': 'x'}, 'a'), 'x');
      expect(Json.optString({'a': 'x'}, 'a'), 'x');
      expect(Json.optString(const {}, 'a'), isNull);
    });

    rejects(
      'a missing required string',
      (j) => Json.requireString(j, 'a'),
      {},
      'a',
    );
    rejects(
      'a required string of the wrong type',
      (j) => Json.requireString(j, 'a'),
      {'a': 7},
      'a',
    );
    rejects(
      'an optional string of the wrong type',
      (j) => Json.optString(j, 'a'),
      {'a': 7},
      'a',
    );
  });

  group('ints', () {
    test('required and optional read through, with a fallback', () {
      expect(Json.requireInt({'a': 7}, 'a'), 7);
      expect(Json.optInt({'a': 7}, 'a'), 7);
      expect(Json.optInt(const {}, 'a'), isNull);
      expect(Json.optInt(const {}, 'a', 3), 3);
    });

    rejects('a missing required int', (j) => Json.requireInt(j, 'a'), {}, 'a');
    rejects('an int field holding a string', (j) => Json.requireInt(j, 'a'), {
      'a': '7',
    }, 'a');
    rejects(
      'an optional int field holding a string',
      (j) => Json.optInt(j, 'a'),
      {'a': '7'},
      'a',
    );
  });

  group('doubles', () {
    test('an int reads as a double', () {
      expect(Json.requireDouble({'a': 7}, 'a'), 7.0);
      expect(Json.optDouble({'a': 7.5}, 'a'), 7.5);
      expect(Json.optDouble(const {}, 'a'), isNull);
      expect(Json.optDouble(const {}, 'a', 1.5), 1.5);
    });

    rejects(
      'a missing required number',
      (j) => Json.requireDouble(j, 'a'),
      {},
      'a',
    );
    rejects(
      'a number field holding a string',
      (j) => Json.requireDouble(j, 'a'),
      {'a': 'x'},
      'a',
    );
    rejects(
      'an optional number field holding a string',
      (j) => Json.optDouble(j, 'a'),
      {'a': 'x'},
      'a',
    );
  });

  group('bools', () {
    test('absent falls back, present reads through', () {
      expect(Json.optBool(const {}, 'a'), isFalse);
      expect(Json.optBool(const {}, 'a', fallback: true), isTrue);
      expect(Json.optBool({'a': true}, 'a'), isTrue);
    });

    rejects('a bool field holding a string', (j) => Json.optBool(j, 'a'), {
      'a': 'yes',
    }, 'a');
  });

  group('timestamps', () {
    test('are normalised to UTC', () {
      final at = Json.requireTimestamp({
        'at': '2026-01-01T09:00:00+02:00',
      }, 'at');
      expect(at.isUtc, isTrue);
      expect(at, DateTime.utc(2026, 1, 1, 7));
      expect(Json.optTimestamp(const {}, 'at'), isNull);
      expect(
        Json.optTimestamp({'at': '2026-01-01T00:00:00Z'}, 'at')!.isUtc,
        isTrue,
      );
    });

    rejects(
      'a required timestamp that does not parse',
      (j) => Json.requireTimestamp(j, 'at'),
      {'at': 'yesterday'},
      'at',
    );
    rejects(
      'an optional timestamp that does not parse',
      (j) => Json.optTimestamp(j, 'at'),
      {'at': 'yesterday'},
      'at',
    );
  });

  group('collections', () {
    test('absent reads as empty, present is stringified', () {
      expect(Json.optStringMap(const {}, 'labels'), isEmpty);
      expect(
        Json.optStringMap({
          'labels': {'env': 'prod', 'n': 1},
        }, 'labels'),
        {'env': 'prod', 'n': '1'},
      );
      expect(Json.optStringList(const {}, 'roles'), isEmpty);
      expect(
        Json.optStringList({
          'roles': ['a', 2],
        }, 'roles'),
        ['a', '2'],
      );
      expect(Json.optObjectList(const {}, 'steps'), isEmpty);
      expect(
        Json.optObjectList({
          'steps': [
            {'formula': 'docker'},
          ],
        }, 'steps'),
        [
          {'formula': 'docker'},
        ],
      );
    });

    rejects(
      'a map field holding a list',
      (j) => Json.optStringMap(j, 'labels'),
      {'labels': <Object?>[]},
      'labels',
    );
    rejects(
      'a list field holding a map',
      (j) => Json.optStringList(j, 'roles'),
      {'roles': <String, Object?>{}},
      'roles',
    );
    rejects(
      'an object-list field holding a string',
      (j) => Json.optObjectList(j, 'steps'),
      {'steps': 'nope'},
      'steps',
    );
    rejects(
      'an object list whose entries are not objects',
      (j) => Json.optObjectList(j, 'steps'),
      {
        'steps': ['nope'],
      },
      'steps',
    );
  });
}
