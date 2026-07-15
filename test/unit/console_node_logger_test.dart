@TestOn('vm')
library;

import 'package:omnyhub/omnyhub_node.dart' as omnyhub;
import 'package:omnyserver/omnyserver_node.dart';
import 'package:test/test.dart';

void main() {
  group('ConsoleNodeLogger', () {
    late List<String> lines;
    late ConsoleNodeLogger logger;

    setUp(() {
      lines = [];
      logger = ConsoleNodeLogger(lines.add);
    });

    test('renders a Hub rejection with its code and reason', () {
      logger.warn(
        'Hub error',
        context: {
          'code': 'forbidden',
          'message':
              'principal server-node may not register node sites-menuici',
        },
      );
      expect(lines, [
        'hub rejected the connection (forbidden): principal server-node may '
            'not register node sites-menuici',
      ]);
    });

    test('renders a connection failure with its cause', () {
      logger.warn(
        'Node connection failed',
        context: {'error': 'Connection refused'},
      );
      expect(lines.single, 'Node connection failed: Connection refused');
    });

    test('drops records below the minimum level', () {
      logger.info('lifecycle detail'); // default minLevel is warn
      logger.debug('noisy');
      expect(lines, isEmpty);
    });

    test('a verbose logger shows the lifecycle', () {
      final verbose = ConsoleNodeLogger(
        lines.add,
        minLevel: omnyhub.LogLevel.debug,
      );
      verbose.info('connecting');
      verbose.debug('handshake');
      expect(lines, ['connecting', 'handshake']);
    });

    // The chosen behaviour: a node that keeps retrying a rejection it cannot fix
    // says why once, not once per backoff.
    test('collapses repeats within the recent window', () {
      for (var i = 0; i < 5; i++) {
        logger.warn(
          'Hub error',
          context: {'code': 'forbidden', 'message': 'no'},
        );
        logger.warn('Node connection failed', context: {'error': 'drop'});
      }
      expect(lines, hasLength(2));
      expect(lines.first, contains('forbidden'));
      expect(lines.last, contains('drop'));
    });

    test('a genuinely new line still prints after repeats', () {
      logger.warn('Hub error', context: {'code': 'forbidden', 'message': 'no'});
      logger.warn('Hub error', context: {'code': 'forbidden', 'message': 'no'});
      logger.warn(
        'Node connection failed',
        context: {'error': 'now registered path changed'},
      );
      expect(lines, hasLength(2));
    });
  });
}
