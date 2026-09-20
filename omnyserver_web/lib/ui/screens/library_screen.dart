import 'dart:async';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/foundation.dart' show AppError;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';
import '../widgets.dart';

/// What the fleet can be made of: blueprints and the presets they compose.
///
/// The two sit on one screen because they are one subject read at two
/// granularities — a blueprint is a machine, a preset is a piece of one — and
/// the question that brings an operator here ("why is `nmap` on that host") is
/// answered by moving between them. Splitting them into two nav entries would
/// make that a navigation problem.
///
/// Only blueprints are assignable to a node; a preset reaches a machine by
/// being included in one. The lists say so, rather than leaving it to be
/// discovered by the absence of a button.
class LibraryScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  @override
  late final web.HTMLElement element;

  late final web.HTMLElement _blueprintsBody;
  late final web.HTMLElement _presetsBody;

  bool _disposed = false;

  /// Builds the screen.
  LibraryScreen(this.ctx) {
    _blueprintsBody = div();
    _presetsBody = div();

    final canOperate = ctx.auth.state.value.canOperate;

    element = el(
      'div',
      classes: 'stack',
      children: [
        el(
          'div',
          classes: 'toolbar row',
          children: [
            el('h1', classes: 'grow', text: 'Library'),
            if (canOperate)
              button('New blueprint', primary: true, onClick: _newBlueprint),
            if (canOperate) button('New preset', onClick: _newPreset),
            button('Refresh', onClick: _load),
          ],
        ),
        el(
          'div',
          classes: 'card stack',
          children: [
            el(
              'div',
              classes: 'row',
              children: [
                el('h2', classes: 'grow', text: 'Blueprints'),
                el('div', classes: 'muted', text: 'assignable to a node'),
              ],
            ),
            _blueprintsBody,
          ],
        ),
        el(
          'div',
          classes: 'card stack',
          children: [
            el(
              'div',
              classes: 'row',
              children: [
                el('h2', classes: 'grow', text: 'Presets'),
                el('div', classes: 'muted', text: 'included by blueprints'),
              ],
            ),
            _presetsBody,
          ],
        ),
      ],
    );

    _load();
  }

  void _load() {
    unawaited(_loadBlueprints());
    unawaited(_loadPresets());
  }

  Future<void> _loadBlueprints() async {
    clearChildren(_blueprintsBody);
    _blueprintsBody.appendChild(loadingRow('Loading blueprints…'));
    try {
      final blueprints = await ctx.service.blueprints();
      if (_disposed) return;
      clearChildren(_blueprintsBody);
      if (blueprints.isEmpty) {
        _blueprintsBody.appendChild(
          emptyState('No blueprints are saved on this Hub.'),
        );
        return;
      }
      for (final blueprint in blueprints) {
        _blueprintsBody.appendChild(_blueprintRow(blueprint));
      }
    } on AppError catch (e) {
      if (_disposed) return;
      clearChildren(_blueprintsBody);
      _blueprintsBody.appendChild(errorBanner(e));
    }
  }

  Future<void> _loadPresets() async {
    clearChildren(_presetsBody);
    _presetsBody.appendChild(loadingRow('Loading presets…'));
    try {
      final presets = await ctx.service.presets();
      if (_disposed) return;
      clearChildren(_presetsBody);
      if (presets.isEmpty) {
        _presetsBody.appendChild(
          emptyState('No presets are saved on this Hub.'),
        );
        return;
      }
      for (final preset in presets) {
        _presetsBody.appendChild(_presetRow(preset));
      }
    } on AppError catch (e) {
      if (_disposed) return;
      clearChildren(_presetsBody);
      _presetsBody.appendChild(errorBanner(e));
    }
  }

  web.HTMLElement _blueprintRow(Blueprint blueprint) => el(
    'div',
    classes: 'row list-item',
    onClick: (_) => ctx.router.go('/library/blueprints/${blueprint.id.value}'),
    children: [
      el(
        'div',
        classes: 'stack grow',
        children: [
          el('strong', text: blueprint.name),
          el(
            'div',
            classes: 'muted',
            text: [
              blueprint.id.value,
              // Counts, because "how big is this" is the only thing worth
              // knowing about a document before opening it.
              '${blueprint.includes.length} include(s)',
              '${blueprint.resources.length} own resource(s)',
              if (blueprint.description.isNotEmpty) blueprint.description,
            ].join(' · '),
          ),
        ],
      ),
      if (blueprint.source != null)
        el('span', classes: 'badge', text: blueprint.source!.format.name),
      if (ctx.auth.state.value.canOperate)
        _deleteButton(
          label: 'Delete ${blueprint.id.value}?',
          // Said plainly, because the Hub does not check: a node assigned to
          // this blueprint keeps its declaration and its drift stops resolving.
          detail:
              'Any node assigned to it keeps the assignment and will fail to '
              'resolve until another blueprint is assigned. Nothing is '
              'removed from any machine.',
          delete: () => ctx.service.deleteBlueprint(blueprint.id.value),
          reload: _loadBlueprints,
        ),
    ],
  );

  web.HTMLElement _presetRow(Preset preset) => el(
    'div',
    classes: 'row list-item',
    onClick: (_) => ctx.router.go('/library/presets/${preset.id.value}'),
    children: [
      el(
        'div',
        classes: 'stack grow',
        children: [
          el('strong', text: preset.name),
          el(
            'div',
            classes: 'muted',
            text: [
              preset.id.value,
              '${preset.steps.length} step(s)',
              if (preset.description.isNotEmpty) preset.description,
            ].join(' · '),
          ),
        ],
      ),
      if (ctx.auth.state.value.canOperate)
        _deleteButton(
          label: 'Delete ${preset.id.value}?',
          detail:
              'A blueprint that includes it will stop resolving until the '
              'preset is put back or the include removed.',
          delete: () => ctx.service.deletePreset(preset.id.value),
          reload: _loadPresets,
        ),
    ],
  );

  /// The row is itself a link, so the click is stopped here — otherwise
  /// confirming a delete also opens the thing being deleted.
  web.HTMLElement _deleteButton({
    required String label,
    required String detail,
    required Future<void> Function() delete,
    required Future<void> Function() reload,
  }) => stopClickPropagation(
    button(
      '✕',
      className: 'icon ghost',
      ariaLabel: label,
      onClick: () => confirmDialog(
        title: label,
        detail: detail,
        action: delete,
        onError: ctx.toasts.error,
        onDone: () {
          ctx.toasts.success('Deleted.');
          unawaited(reload());
        },
        confirmLabel: 'Delete',
      ),
    ),
  );

  /// Creating is naming: the document itself is written on the detail screen,
  /// which is where the editor and the Hub's validation already live.
  ///
  /// The starting document is a real, valid blueprint rather than an empty box
  /// — the shape is most of what somebody needs to be told, and a saved
  /// blueprint that declares nothing is a legitimate thing to build from.
  void _newBlueprint() {
    final id = input(
      id: 'new-blueprint-id',
      placeholder: 'web-server',
      autocapitalize: 'off',
    );

    late final Modal modal;
    modal = Modal(
      title: 'New blueprint',
      body: el(
        'div',
        classes: 'stack',
        children: [
          field(
            'Id',
            id,
            hint: 'How nodes refer to it. It cannot be changed later.',
          ),
          el(
            'div',
            classes: 'hint',
            text:
                'A starting document is saved, in YAML. Edit it on the next '
                'screen — nothing runs until a node is assigned and '
                'reconciled.',
          ),
        ],
      ),
      actions: [
        button('Cancel', onClick: () => modal.close()),
        button(
          'Create',
          primary: true,
          onClick: () async {
            final value = id.value.trim();
            if (value.isEmpty) {
              ctx.toasts.error('Name it first.');
              return;
            }
            modal.close();
            try {
              await ctx.service.saveBlueprint(
                parseBlueprint(
                  _starterBlueprint(value),
                  BlueprintFormat.yaml,
                  origin: 'the new blueprint',
                ),
              );
              ctx.router.go('/library/blueprints/$value');
            } on AppError catch (e) {
              ctx.toasts.error(e.message);
            } on OmnyServerException catch (e) {
              ctx.toasts.error(e.message);
            }
          },
        ),
      ],
    );
    modal.show();
  }

  void _newPreset() {
    final id = input(
      id: 'new-preset-id',
      placeholder: 'base-tools',
      autocapitalize: 'off',
    );

    late final Modal modal;
    modal = Modal(
      title: 'New preset',
      body: el(
        'div',
        classes: 'stack',
        children: [
          field(
            'Id',
            id,
            hint: 'How blueprints include it. It cannot be changed later.',
          ),
        ],
      ),
      actions: [
        button('Cancel', onClick: () => modal.close()),
        button(
          'Create',
          primary: true,
          onClick: () async {
            final value = id.value.trim();
            if (value.isEmpty) {
              ctx.toasts.error('Name it first.');
              return;
            }
            modal.close();
            try {
              await ctx.service.savePreset(
                Preset(id: PresetId(value), name: value),
              );
              ctx.router.go('/library/presets/$value');
            } on AppError catch (e) {
              ctx.toasts.error(e.message);
            } on OmnyServerException catch (e) {
              ctx.toasts.error(e.message);
            }
          },
        ),
      ],
    );
    modal.show();
  }

  static String _starterBlueprint(String id) =>
      '# What a $id should be.\n'
      'blueprint: $id\n'
      'name: $id\n'
      '\n'
      '# Presets to fold in, in order. They are tracked, not pinned:\n'
      '# editing one re-resolves every blueprint that includes it.\n'
      'includes: []\n'
      '\n'
      '# Each resource declares a state, never an action.\n'
      'resources: []\n';

  @override
  void dispose() {
    _disposed = true;
  }
}
