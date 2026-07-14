import 'dart:async';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/foundation.dart' show AppError;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';

/// The operational half of a node's screen: what it is declared to be, and what
/// you can run on it.
///
/// Kept apart from the node's *description* because these are the parts that
/// change a machine, and every one of them is gated on the operator's roles — a
/// viewer sees the state of the world and none of these controls.
class NodeOperations {
  /// The app context.
  final AppContext ctx;

  /// The node being operated.
  final String nodeId;

  /// The panel's root.
  final web.HTMLElement element = el('div', classes: 'stack');

  final web.HTMLElement _driftBody = div();
  final web.HTMLElement _runBody = div();
  final web.HTMLElement _opsBody = div();
  StreamSubscription<OmnyEvent>? _events;
  bool _disposed = false;

  List<FormulaSpec> _formulas = const [];
  List<Preset> _presets = const [];

  /// Builds the panel.
  NodeOperations(this.ctx, this.nodeId) {
    element
      ..appendChild(
        el(
          'div',
          classes: 'card stack',
          children: [
            el('h3', text: 'Declared state'),
            _driftBody,
          ],
        ),
      )
      ..appendChild(
        el(
          'div',
          classes: 'card stack',
          children: [
            el('h3', text: 'Run'),
            _runBody,
          ],
        ),
      )
      ..appendChild(
        el(
          'div',
          classes: 'card stack',
          children: [
            el('h3', text: 'Operations'),
            _opsBody,
          ],
        ),
      );

    unawaited(_loadDrift());
    unawaited(_loadCatalog());
    unawaited(_loadOperations());
    _watchOperations();
  }

  /// Re-reads the tray when an operation on *this* node starts or finishes.
  ///
  /// On the event stream, not a poll: an operation announces itself, so a client
  /// that polled would either ask too often or find out too late.
  void _watchOperations() {
    _events = ctx.service.eventStream().listen((event) {
      // The pattern binds `node`, not `nodeId`: destructuring into a name that
      // shadows the field would compare the event to itself, and every operation
      // on the fleet would look like one of ours.
      final mine = switch (event) {
        OperationStarted(nodeId: final node) => node.value == nodeId,
        OperationFinished(nodeId: final node) => node.value == nodeId,
        _ => false,
      };
      if (mine) unawaited(_loadOperations());
    }, onError: (Object _) {});
  }

  /// What is running on this node, and how the last few went.
  Future<void> _loadOperations() async {
    try {
      final operations = await ctx.service.operations(nodeId: nodeId);
      if (_disposed) return;
      clearChildren(_opsBody);

      if (operations.isEmpty) {
        _opsBody.appendChild(
          emptyState('Nothing has been dispatched to this node.'),
        );
        return;
      }

      final now = DateTime.now();
      for (final op in operations.take(10)) {
        _opsBody.appendChild(
          el(
            'div',
            classes: 'row',
            children: [
              el(
                'span',
                classes: switch (op.status) {
                  OperationStatus.running => 'badge',
                  OperationStatus.succeeded => 'badge online',
                  OperationStatus.failed => 'badge offline',
                },
                text: op.status.name,
              ),
              el('div', classes: 'grow', text: '${op.kind} ${op.summary}'),
              el(
                'div',
                classes: 'muted mono',
                text: '${op.duration(now).inSeconds}s',
              ),
            ],
          ),
        );
        if (op.error != null) {
          _opsBody.appendChild(el('div', classes: 'hint', text: op.error!));
        }
      }
    } on AppError {
      // The controls above still work; a failed tray read should not take them
      // down with it.
    }
  }

  /// Releases the event subscription.
  void dispose() {
    _disposed = true;
    unawaited(_events?.cancel());
  }

  // --- Declared state and drift ---------------------------------------------

  Future<void> _loadDrift() async {
    clearChildren(_driftBody);
    _driftBody.appendChild(loadingRow('Checking for drift…'));
    try {
      final drift = await ctx.service.drift(nodeId);
      clearChildren(_driftBody);

      if (drift == null) {
        // Not an error, and not "converged": nobody has made a claim about this
        // node, so there is nothing it could have drifted *from*.
        _driftBody.appendChild(
          emptyState('Nothing is declared for this node.'),
        );
        _driftBody.appendChild(_declareControls());
        return;
      }

      _driftBody.appendChild(
        el(
          'div',
          classes: 'row',
          children: [
            el(
              'span',
              classes: drift.converged ? 'badge online' : 'badge offline',
              text: drift.converged ? 'converged' : 'drifted',
            ),
            el(
              'div',
              classes: 'grow muted',
              text: drift.converged
                  ? 'The node still is what it was declared to be.'
                  : '${drift.actions.length} step(s) would have to run.',
            ),
          ],
        ),
      );

      for (final step in drift.actions) {
        _driftBody.appendChild(
          el(
            'div',
            classes: 'row mono',
            children: [
              el(
                'div',
                classes: 'grow',
                text: '${step.action.name} ${step.formula.value}',
              ),
            ],
          ),
        );
      }

      if (ctx.auth.state.value.canOperate) {
        _driftBody.appendChild(
          el(
            'div',
            classes: 'row',
            children: [
              button(
                drift.converged ? 'Reconcile anyway' : 'Reconcile',
                primary: !drift.converged,
                onClick: _reconcile,
              ),
              button('Undeclare', className: 'ghost', onClick: _undeclare),
            ],
          ),
        );
      }
    } on AppError catch (e) {
      clearChildren(_driftBody);
      _driftBody.appendChild(errorBanner(e));
    }
  }

  /// Declaring is done from the preset library: a declaration is "this node is
  /// one of *these*", and inventing a bespoke one per node is how a fleet stops
  /// being a fleet.
  web.HTMLElement _declareControls() {
    if (!ctx.auth.state.value.canOperate) return div();
    if (_presets.isEmpty) {
      return el(
        'div',
        classes: 'hint',
        text: 'Save a preset on the Hub to declare a state from it.',
      );
    }

    final select = _presetSelect();
    return el(
      'div',
      classes: 'row',
      children: [
        select,
        button(
          'Declare',
          onClick: () async {
            final preset = _presets.firstWhere(
              (p) => p.id.value == select.value,
            );
            try {
              await ctx.service.declare(nodeId, preset.toJson());
              // Said explicitly: an operator who expects this to have *done*
              // something will otherwise wonder why the machine is unchanged.
              ctx.toasts.success(
                'Declared. Nothing has run — reconcile to apply.',
              );
              await _loadDrift();
            } on AppError catch (e) {
              ctx.toasts.error(e.message);
            }
          },
        ),
      ],
    );
  }

  Future<void> _reconcile() async {
    try {
      final results = await ctx.service.reconcile(nodeId);
      ctx.toasts.success(
        results.isEmpty
            ? 'Already converged — nothing to do.'
            : 'Ran ${results.length} step(s).',
      );
      await _loadDrift();
    } on AppError catch (e) {
      ctx.toasts.error(e.message);
    }
  }

  Future<void> _undeclare() async {
    try {
      await ctx.service.undeclare(nodeId);
      ctx.toasts.show('Stopped expecting anything of $nodeId.');
      await _loadDrift();
    } on AppError catch (e) {
      ctx.toasts.error(e.message);
    }
  }

  // --- Formulas and presets --------------------------------------------------

  Future<void> _loadCatalog() async {
    clearChildren(_runBody);
    _runBody.appendChild(loadingRow('Loading the catalogue…'));
    try {
      _formulas = await ctx.service.formulas();
      _presets = await ctx.service.presets();
      _renderRun();
      // The declare controls need the preset list, which has only just arrived.
      await _loadDrift();
    } on AppError catch (e) {
      clearChildren(_runBody);
      _runBody.appendChild(errorBanner(e));
    }
  }

  void _renderRun() {
    clearChildren(_runBody);

    if (!ctx.auth.state.value.canOperate) {
      _runBody.appendChild(
        el(
          'div',
          classes: 'hint',
          text: 'Your roles do not permit running anything on this node.',
        ),
      );
      return;
    }

    // A formula and its actions come from the Hub's catalogue, so the UI offers
    // what the node can actually do instead of a text box to get wrong.
    final formulaSelect = _select(
      id: 'formula',
      options: [for (final f in _formulas) (value: f.id.value, label: f.name)],
    );
    final actionSelect = _select(id: 'action', options: const []);

    void syncActions() {
      final spec = _formulas.firstWhere(
        (f) => f.id.value == formulaSelect.value,
        orElse: () => _formulas.first,
      );
      clearChildren(actionSelect);
      for (final action in spec.actions) {
        final option = el('option', text: action.name) as web.HTMLOptionElement;
        option.value = action.name;
        actionSelect.appendChild(option);
      }
    }

    if (_formulas.isNotEmpty) {
      syncActions();
      on(formulaSelect, 'change', (_) => syncActions());

      _runBody.appendChild(
        el(
          'div',
          classes: 'row',
          children: [
            formulaSelect,
            actionSelect,
            button(
              'Run formula',
              onClick: () => _runFormula(
                formulaSelect.value,
                FormulaAction.parse(actionSelect.value),
              ),
            ),
          ],
        ),
      );
    }

    if (_presets.isNotEmpty) {
      final presetSelect = _presetSelect();
      _runBody.appendChild(
        el(
          'div',
          classes: 'row',
          children: [
            presetSelect,
            button(
              'Apply preset',
              onClick: () => _applyPreset(presetSelect.value),
            ),
          ],
        ),
      );
    } else {
      _runBody.appendChild(
        el(
          'div',
          classes: 'hint',
          text: 'No presets are saved on the Hub yet.',
        ),
      );
    }
  }

  /// Dispatched, not awaited.
  ///
  /// A browser tab is the worst possible place to wait on an `install`: the
  /// request times out, the node carries on working, and the operator is shown a
  /// failure that did not happen. The operations tray below is where the answer
  /// arrives.
  Future<void> _runFormula(String formula, FormulaAction action) async {
    try {
      await ctx.service.runFormulaAsync(
        nodeId,
        formula: formula,
        action: action,
      );
      ctx.toasts.show('$formula ${action.name} dispatched.');
      await _loadOperations();
    } on AppError catch (e) {
      ctx.toasts.error(e.message);
    }
  }

  Future<void> _applyPreset(String presetId) async {
    try {
      await ctx.service.applySavedPresetAsync(nodeId, presetId);
      ctx.toasts.show('Applying $presetId…');
      await _loadOperations();
    } on AppError catch (e) {
      ctx.toasts.error(e.message);
    }
  }

  web.HTMLSelectElement _presetSelect() => _select(
    id: 'preset',
    options: [
      for (final p in _presets)
        (value: p.id.value, label: '${p.name} (${p.steps.length} steps)'),
    ],
  );

  web.HTMLSelectElement _select({
    required String id,
    required List<({String value, String label})> options,
  }) {
    final select = el('select', id: id) as web.HTMLSelectElement;
    for (final option in options) {
      final node = el('option', text: option.label) as web.HTMLOptionElement;
      node.value = option.value;
      select.appendChild(node);
    }
    return select;
  }
}
