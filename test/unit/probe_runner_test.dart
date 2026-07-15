@TestOn('vm && !windows')
library;

import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

void main() {
  group('runProbe', () {
    test('returns the result of a fast command', () async {
      final result = await runProbe('printf', ['hello']);
      expect(result, isNotNull);
      expect(result!.exitCode, 0);
      expect(result.stdout, 'hello');
    });

    test('returns null for a missing executable', () async {
      final result = await runProbe('definitely-not-a-real-binary-xyz', []);
      expect(result, isNull);
    });

    // The whole point: a wedged probe must not hang registration. `sleep 30`
    // stands in for a stuck `nvidia-smi`; the deadline kills it and reports
    // "not detected" fast.
    test(
      'kills and returns null when the command exceeds the timeout',
      () async {
        final stopwatch = Stopwatch()..start();
        final result = await runProbe('sleep', [
          '30',
        ], timeout: const Duration(milliseconds: 300));
        stopwatch.stop();
        expect(result, isNull);
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 5)),
          reason: 'the probe must be killed at the deadline, not waited out',
        );
      },
    );

    test('a non-zero exit still returns (the caller decides)', () async {
      final result = await runProbe('sh', ['-c', 'exit 3']);
      expect(result, isNotNull);
      expect(result!.exitCode, 3);
    });
  });
}
