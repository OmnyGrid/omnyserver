import 'package:uuid/uuid.dart';

/// Generates opaque, unique identifiers (session ids, audit ids, request ids).
///
/// Injectable so tests can substitute a deterministic generator.
abstract class IdGenerator {
  /// Returns a fresh, unique identifier.
  String next();
}

/// The default [IdGenerator], backed by random (v4) UUIDs.
class UuidGenerator implements IdGenerator {
  static const Uuid _uuid = Uuid();

  /// Creates a UUID-backed generator.
  const UuidGenerator();

  @override
  String next() => _uuid.v4();
}
