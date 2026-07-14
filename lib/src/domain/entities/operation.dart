import 'package:meta/meta.dart';

import '../../shared/errors/omnyserver_exception.dart';
import '../../shared/json/json_codec_helpers.dart';

/// Where an [Operation] has got to.
enum OperationStatus {
  /// Dispatched to the node, still working.
  running,

  /// Finished, and did what was asked.
  succeeded,

  /// Finished, and did not.
  failed;

  /// Parses a status, rejecting anything else.
  static OperationStatus parse(String value) =>
      OperationStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () =>
            throw ProtocolException('unknown operation status "$value"'),
      );
}

/// Something the Hub is doing to a node, that takes long enough to be worth a
/// name.
///
/// `formula run` and `preset apply` answer synchronously: the caller waits, and
/// the Hub gives up after `requestTimeout`. That is right for a `verify` — and
/// wrong for an `install`, which can take minutes. The caller gets a timeout, the
/// node carries on working, and the operator is told a failure that did not
/// happen.
///
/// An operation is the alternative: dispatch, get an id back at once, and ask
/// about it later. The work is the same work; only who waits for it changes.
@immutable
class Operation {
  /// A stable id, to ask about it later.
  final String id;

  /// What is being done (`formula`, `preset`, `reconcile`).
  final String kind;

  /// The node it is being done to.
  final String nodeId;

  /// Who asked for it.
  final String principal;

  /// Where it has got to.
  final OperationStatus status;

  /// A short description of what was asked (`docker install`, `docker-host`).
  final String summary;

  /// When it was dispatched (UTC).
  final DateTime startedAt;

  /// When it finished, or `null` while it is still running.
  final DateTime? finishedAt;

  /// The result, once finished — the same body the synchronous call returns, so
  /// nothing has to be decoded differently just because it was awaited later.
  final Map<String, dynamic>? result;

  /// Why it failed, if it did.
  final String? error;

  /// Creates an operation.
  const Operation({
    required this.id,
    required this.kind,
    required this.nodeId,
    required this.principal,
    required this.status,
    required this.summary,
    required this.startedAt,
    this.finishedAt,
    this.result,
    this.error,
  });

  /// Whether it is still working.
  bool get isRunning => status == OperationStatus.running;

  /// How long it took, or has been going.
  Duration duration(DateTime now) => (finishedAt ?? now).difference(startedAt);

  /// A copy of this operation, finished.
  Operation completed({
    required OperationStatus status,
    required DateTime at,
    Map<String, dynamic>? result,
    String? error,
  }) => Operation(
    id: id,
    kind: kind,
    nodeId: nodeId,
    principal: principal,
    status: status,
    summary: summary,
    startedAt: startedAt,
    finishedAt: at,
    result: result,
    error: error,
  );

  /// JSON form.
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'nodeId': nodeId,
    'principal': principal,
    'status': status.name,
    'summary': summary,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'finishedAt': ?finishedAt?.toUtc().toIso8601String(),
    'result': ?result,
    'error': ?error,
  };

  /// Decodes from JSON.
  static Operation fromJson(Map<String, dynamic> json) => Operation(
    id: Json.requireString(json, 'id'),
    kind: Json.requireString(json, 'kind'),
    nodeId: Json.requireString(json, 'nodeId'),
    principal: Json.optString(json, 'principal') ?? 'system',
    status: OperationStatus.parse(Json.requireString(json, 'status')),
    summary: Json.optString(json, 'summary') ?? '',
    startedAt: Json.requireTimestamp(json, 'startedAt'),
    finishedAt: Json.optTimestamp(json, 'finishedAt'),
    result: json['result'] is Map
        ? (json['result'] as Map).cast<String, dynamic>()
        : null,
    error: Json.optString(json, 'error'),
  );

  @override
  String toString() =>
      'Operation($id, $kind $summary on $nodeId, ${status.name})';
}
