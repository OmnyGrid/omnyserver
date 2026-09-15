import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs [action] with `stdout` redirected into a buffer, and returns everything
/// it wrote.
///
/// The CLI reports through `stdout` — a masked key, a cleared value, a rendered
/// service definition, a table of samples — and that output *is* the behaviour
/// worth asserting on. Running the commands in-process rather than as a
/// subprocess is what makes their coverage visible to the VM collector; this is
/// how a test reads what they printed.
Future<String> captureStdout(
  Future<void> Function() action, {
  StringBuffer? into,
}) async {
  final buffer = into ?? StringBuffer();
  await IOOverrides.runZoned(action, stdout: () => BufferedStdout(buffer));
  return buffer.toString();
}

/// Runs [action] with `stdin` answering [lines] in order and `stdout` captured.
///
/// For the commands that prompt — `ai config --key -` reads the key from a
/// hidden prompt rather than the command line, precisely so it never reaches
/// the shell history a test would otherwise have to fake.
Future<String> captureStdio(
  Future<void> Function() action, {
  required List<String> lines,
}) async {
  final buffer = StringBuffer();
  await IOOverrides.runZoned(
    action,
    stdout: () => BufferedStdout(buffer),
    stdin: () => ScriptedStdin(lines),
  );
  return buffer.toString();
}

/// A [Stdout] that appends to a [StringBuffer] instead of reaching a terminal.
///
/// It reports no terminal, so anything asking about width or ANSI support gets
/// the same answer a pipe would give.
class BufferedStdout implements Stdout {
  final StringBuffer _buffer;

  /// Writes everything into [_buffer].
  BufferedStdout(this._buffer);

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void add(List<int> data) => _buffer.write(utf8.decode(data));

  @override
  Encoding get encoding => utf8;

  @override
  set encoding(Encoding value) {}

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  int get terminalColumns => 80;

  @override
  int get terminalLines => 24;

  @override
  String get lineTerminator => '\n';

  @override
  set lineTerminator(String value) {}

  @override
  IOSink get nonBlocking => this;

  @override
  Future<void> get done async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) => throw error;

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);
}

/// A [Stdin] that answers [_lines] in order, then end-of-input.
///
/// It reports no terminal, which is also the honest answer under a test runner:
/// the code that turns echo off checks for one first, so this exercises the
/// non-terminal path rather than trying to fake `termios`.
class ScriptedStdin extends Stream<List<int>> implements Stdin {
  final List<String> _lines;
  int _next = 0;

  /// Answers each prompt with the next of [_lines].
  ScriptedStdin(this._lines);

  @override
  String? readLineSync({
    Encoding encoding = systemEncoding,
    bool retainNewlines = false,
  }) => _next < _lines.length ? _lines[_next++] : null;

  @override
  int readByteSync() => -1;

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  bool echoMode = true;

  @override
  bool echoNewlineMode = true;

  @override
  bool lineMode = true;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<List<int>>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
