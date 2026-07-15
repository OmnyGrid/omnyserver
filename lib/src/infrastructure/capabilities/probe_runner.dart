import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs a capability-probe command with a hard [timeout], returning its result
/// or `null` if it could not run or did not finish in time.
///
/// Capability detection shells out to tools like `docker`, `nvidia-smi` and
/// `clinfo`. Some of those hang — a wedged Docker daemon, a half-installed GPU
/// driver — and the scanner awaits *every* probe before a node can register, so
/// one stuck command with no deadline freezes registration entirely, silently.
/// This bounds each probe: on timeout the process is killed and the capability
/// is simply treated as absent, which is the right answer for a tool that
/// cannot even report its own version.
///
/// A missing executable ([ProcessException]) returns `null` too, so a caller
/// never has to distinguish "not installed" from "timed out" — both mean the
/// capability is not usable.
Future<ProcessResult?> runProbe(
  String executable,
  List<String> args, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final Process process;
  try {
    process = await Process.start(executable, args);
  } on ProcessException {
    return null;
  }

  // Drain both pipes so a chatty process cannot block on a full stdout buffer
  // while we wait for it to exit.
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();

  try {
    final exitCode = await process.exitCode.timeout(timeout);
    final out = await stdoutFuture;
    final err = await stderrFuture;
    return ProcessResult(process.pid, exitCode, out, err);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    // Let the killed process's streams close rather than leaking subscriptions.
    unawaited(stdoutFuture.catchError((_) => ''));
    unawaited(stderrFuture.catchError((_) => ''));
    return null;
  }
}
