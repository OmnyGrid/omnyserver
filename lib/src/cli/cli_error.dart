/// A user-facing CLI error (printed without a stack trace).
class CliError implements Exception {
  /// The message shown to the user.
  final String message;

  /// Creates a CLI error.
  CliError(this.message);

  @override
  String toString() => message;
}
