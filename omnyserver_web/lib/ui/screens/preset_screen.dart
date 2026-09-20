import 'dart:async';
import 'dart:convert';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/foundation.dart' show AppError;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';
import '../widgets.dart';

/// One preset: the ordered steps a blueprint folds in by including it.
///
/// Narrower than [BlueprintScreen] and deliberately so. A preset has no
/// includes to flatten and no variables to substitute, so there is nothing for
/// a Resolved view to show that the steps do not already say; and a preset is
/// not assignable to a node, so there is nothing to assign.
///
/// Authored as JSON, not YAML. The browser could parse YAML here — the parser
/// is web-safe — but `preset save` on the CLI takes JSON only, and a dashboard
/// that accepts a format the CLI rejects is a worse wart than the one it fixes.
/// Worth doing properly later, on both sides at once.
class PresetScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  /// Which preset.
  final String presetId;

  @override
  late final web.HTMLElement element;

  late final web.HTMLElement _title;
  late final web.HTMLElement _body;

  Preset? _preset;
  web.HTMLTextAreaElement? _editor;
  bool _disposed = false;

  /// Builds the screen.
  PresetScreen(this.ctx, this.presetId) {
    _title = el('h1', classes: 'grow', text: presetId);
    _body = div(classes: 'stack');

    element = el(
      'div',
      classes: 'stack',
      children: [
        el(
          'div',
          classes: 'toolbar row',
          children: [
            button('← Library', onClick: () => ctx.router.go(Routes.library)),
            _title,
            if (ctx.auth.state.value.canOperate)
              button('Delete', className: 'danger', onClick: _delete),
          ],
        ),
        el('div', classes: 'card stack', children: [_body]),
      ],
    );

    unawaited(_load());
  }

  Future<void> _load() async {
    clearChildren(_body);
    _body.appendChild(loadingRow('Loading $presetId…'));
    try {
      final preset = await ctx.service.preset(presetId);
      if (_disposed) return;
      _preset = preset;
      _title.textContent = preset.name;
      _render();
    } on AppError catch (e) {
      if (_disposed) return;
      clearChildren(_body);
      _body.appendChild(errorBanner(e));
    }
  }

  void _render() {
    final preset = _preset;
    if (preset == null) return;

    clearChildren(_body);
    _body.appendChild(el('h2', text: 'Steps'));

    // The steps first, read as steps: the JSON below is how they are edited,
    // not how they are best understood.
    if (preset.steps.isEmpty) {
      _body.appendChild(emptyState('This preset declares no steps.'));
    } else {
      for (final step in preset.steps) {
        _body.appendChild(
          el(
            'div',
            classes: 'row mono',
            children: [
              el('span', classes: 'badge', text: step.action.name),
              el('div', classes: 'grow', text: step.formula.value),
              if (step.version case final version?)
                el('div', classes: 'muted', text: version),
            ],
          ),
        );
      }
    }

    final document = const JsonEncoder.withIndent(
      '  ',
    ).convert(preset.toJson());

    if (!ctx.auth.state.value.canOperate) {
      _editor = null;
      _body.appendChild(el('pre', classes: 'screen-capture', text: document));
      return;
    }

    final box = textarea(id: 'preset-source', value: document, rows: 16);
    _editor = box;
    _body
      ..appendChild(box)
      ..appendChild(
        el(
          'div',
          classes: 'row',
          children: [
            el(
              'div',
              classes: 'grow hint',
              text:
                  'Editing a shared preset re-resolves every blueprint that '
                  'includes it. Nothing runs until a node is reconciled.',
            ),
            button('Revert', onClick: _render),
            button('Save', primary: true, onClick: _save),
          ],
        ),
      );
  }

  Future<void> _save() async {
    final editor = _editor;
    if (editor == null) return;
    try {
      final decoded = jsonDecode(editor.value);
      if (decoded is! Map) {
        throw const ProtocolException(
          'A preset is an object, not a list or a scalar.',
        );
      }
      final parsed = Preset.fromJson(decoded.cast<String, dynamic>());
      if (parsed.id.value != presetId) {
        throw ProtocolException(
          'The id is how blueprints include this preset and cannot be changed '
          'by editing — "${parsed.id.value}" is a different preset.',
        );
      }
      await ctx.service.savePreset(parsed);
      ctx.toasts.success('Saved.');
      await _load();
    } on FormatException catch (e) {
      ctx.toasts.error('Not valid JSON: ${e.message}');
    } on AppError catch (e) {
      ctx.toasts.error(e.message);
    } on OmnyServerException catch (e) {
      ctx.toasts.error(e.message);
    }
  }

  void _delete() => confirmDialog(
    title: 'Delete $presetId?',
    detail:
        'A blueprint that includes it will stop resolving until the preset is '
        'put back or the include removed. Nothing is removed from any machine.',
    action: () => ctx.service.deletePreset(presetId),
    onError: ctx.toasts.error,
    onDone: () {
      ctx.toasts.success('Deleted.');
      ctx.router.go(Routes.library);
    },
    confirmLabel: 'Delete',
  );

  @override
  void dispose() {
    _disposed = true;
  }
}
