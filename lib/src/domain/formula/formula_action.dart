/// The operational steps a [Formula] supports.
enum FormulaAction {
  /// Install the managed software.
  install,

  /// Update the managed software to a newer version.
  update,

  /// Start the managed service.
  start,

  /// Stop the managed service.
  stop,

  /// Restart the managed service.
  restart,

  /// Uninstall the managed software.
  uninstall,

  /// Validate that the managed software is present and healthy.
  verify;

  /// Parses a wire name to a [FormulaAction], defaulting to [verify].
  static FormulaAction parse(String value) => FormulaAction.values.firstWhere(
    (a) => a.name == value,
    orElse: () => FormulaAction.verify,
  );
}
