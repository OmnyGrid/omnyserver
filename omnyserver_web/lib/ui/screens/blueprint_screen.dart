import 'dart:async';

import 'package:omnyserver/omnyserver_client_web.dart';
import 'package:omnyshell_web/foundation.dart' show AppError;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import '../../app/app_context.dart';
import '../widgets.dart';

/// One blueprint: what it says, what it resolves to, and which nodes get it.
///
/// Two views of one document, because they answer different questions and
/// neither substitutes for the other. **Source** is what a human wrote —
/// comments, includes, `${vars}` — and is the only thing that can be edited.
/// **Resolved** is what a node is actually sent: the includes flattened,
/// variables substituted, resources in the order they will be settled, each
/// naming where it came from. When a blueprint is not doing what its author
/// expected, the difference between the two *is* the answer.
///
/// Editing is on Source only, and never on Resolved — a resolved list is
/// derived, and letting somebody edit a derivation is how the two quietly stop
/// agreeing.
class BlueprintScreen implements Screen {
  /// The app context.
  final AppContext ctx;

  /// Which blueprint.
  final String blueprintId;

  @override
  late final web.HTMLElement element;

  late final web.HTMLElement _title;
  late final web.HTMLElement _documentBody;
  late final web.HTMLElement _assignBody;
  late final web.HTMLElement _selectorsBody;
  late final web.HTMLElement _matchesBody;

  Blueprint? _blueprint;
  web.HTMLTextAreaElement? _editor;
  String _view = 'source';
  bool _disposed = false;

  /// The nodes the last Preview matched, so Assign acts on what was shown
  /// rather than on whatever the label box says by then.
  List<NodeDescriptor> _matches = const [];

  /// Builds the screen.
  BlueprintScreen(this.ctx, this.blueprintId) {
    _title = el('h1', classes: 'grow', text: blueprintId);
    _documentBody = div(classes: 'stack');
    _assignBody = div(classes: 'stack');
    _selectorsBody = div();
    _matchesBody = div();

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
        el('div', classes: 'card stack', children: [_documentBody]),
        el('div', classes: 'card stack', children: [_assignBody]),
      ],
    );

    unawaited(_load());
  }

  Future<void> _load() async {
    clearChildren(_documentBody);
    _documentBody.appendChild(loadingRow('Loading $blueprintId…'));
    try {
      final blueprint = await ctx.service.blueprint(blueprintId);
      if (_disposed) return;
      _blueprint = blueprint;
      _title.textContent = blueprint.name;
      _renderDocument();
      _renderAssign();
    } on AppError catch (e) {
      if (_disposed) return;
      clearChildren(_documentBody);
      _documentBody.appendChild(errorBanner(e));
    }
  }

  void _renderDocument() {
    final blueprint = _blueprint;
    if (blueprint == null) return;

    clearChildren(_documentBody);
    _documentBody.appendChild(
      el(
        'div',
        classes: 'row',
        children: [
          el('h2', classes: 'grow', text: 'Document'),
          radioGroup(
            name: 'blueprint-view',
            ariaLabel: 'Which view of the blueprint',
            inline: true,
            selected: _view,
            options: const [
              (value: 'source', label: 'Source'),
              (value: 'resolved', label: 'Resolved'),
            ],
            onChange: (value) {
              _view = value;
              _renderDocument();
            },
          ),
        ],
      ),
    );

    if (_view == 'resolved') {
      _editor = null;
      _renderResolved();
      return;
    }

    final source = blueprint.source;
    if (source == null) {
      // Saved through the API as JSON rather than authored as a document. There
      // is nothing verbatim to show, and inventing one would mean claiming
      // somebody wrote it.
      _editor = null;
      _documentBody.appendChild(
        emptyState('This blueprint was saved without a source document.'),
      );
      _documentBody.appendChild(
        el(
          'div',
          classes: 'hint',
          text: 'Its resolved form is still readable — switch to Resolved.',
        ),
      );
      return;
    }

    final editable = ctx.auth.state.value.canOperate;
    if (!editable) {
      _editor = null;
      _documentBody.appendChild(
        el('pre', classes: 'screen-capture', text: source.text),
      );
      return;
    }

    final box = textarea(id: 'blueprint-source', value: source.text, rows: 22);
    _editor = box;
    _documentBody.appendChild(box);
    _documentBody.appendChild(
      el(
        'div',
        classes: 'row',
        children: [
          el(
            'div',
            classes: 'grow hint',
            text:
                'Written as ${source.format.name}. Saving validates it on the '
                'Hub; nothing runs until a node is reconciled.',
          ),
          button('Revert', onClick: _renderDocument),
          button('Save', primary: true, onClick: _save),
        ],
      ),
    );
  }

  void _renderResolved() {
    final body = div(classes: 'stack');
    _documentBody.appendChild(body);
    body.appendChild(loadingRow('Resolving…'));

    unawaited(() async {
      try {
        final resolved = await ctx.service.resolvedBlueprint(blueprintId);
        if (_disposed || _view != 'resolved') return;
        clearChildren(body);
        body.appendChild(
          el(
            'div',
            classes: 'row',
            children: [
              el(
                'div',
                classes: 'grow muted',
                text:
                    '${resolved.resources.length} resource(s), in the order '
                    'they are settled.',
              ),
              // The hash is how "this node is behind" is decided, so it is
              // worth being able to read it off both ends.
              el(
                'span',
                classes: 'badge mono',
                text: _shortHash(resolved.hash),
              ),
            ],
          ),
        );
        for (final resource in resolved.resources) {
          body.appendChild(_resolvedRow(resource));
        }
        for (final note in resolved.notes) {
          body.appendChild(el('div', classes: 'hint', text: note));
        }
      } on AppError catch (e) {
        if (_disposed || _view != 'resolved') return;
        clearChildren(body);
        body.appendChild(errorBanner(e));
      }
    }());
  }

  web.HTMLElement _resolvedRow(ResolvedResource resource) => el(
    'div',
    classes: 'stack',
    children: [
      el(
        'div',
        classes: 'row mono',
        children: [
          el('span', classes: 'badge', text: resource.ensure.name),
          el('div', classes: 'grow', text: resource.id.toString()),
          el('div', classes: 'muted', text: resource.origin),
        ],
      ),
      // An override is legitimate — "the base says running, this role says
      // stopped" — but it must never be silent.
      if (resource.overrides case final overridden?)
        el('div', classes: 'hint', text: 'overrides $overridden'),
      if (resource.resource.requires.isNotEmpty)
        el(
          'div',
          classes: 'hint',
          text: 'after ${resource.resource.requires.join(', ')}',
        ),
    ],
  );

  Future<void> _save() async {
    final editor = _editor;
    final source = _blueprint?.source;
    if (editor == null || source == null) return;
    try {
      // Parsed here so a typo is reported against the text in front of the
      // author, with the line the parser objected to, rather than as a 400 from
      // a Hub that was sent nothing it could read.
      final parsed = parseBlueprint(
        editor.value,
        source.format,
        origin: 'this blueprint',
      );
      if (parsed.id.value != blueprintId) {
        throw ProtocolException(
          'The id is how nodes refer to this blueprint and cannot be changed '
          'by editing — "${parsed.id.value}" is a different blueprint.',
        );
      }
      await ctx.service.saveBlueprint(parsed);
      ctx.toasts.success('Saved. Reconcile a node to apply it.');
      await _load();
    } on AppError catch (e) {
      ctx.toasts.error(e.message);
    } on OmnyServerException catch (e) {
      ctx.toasts.error(e.message);
    }
  }

  void _delete() => confirmDialog(
    title: 'Delete $blueprintId?',
    detail:
        'Any node assigned to it keeps the assignment and will fail to resolve '
        'until another blueprint is assigned. Nothing is removed from any '
        'machine.',
    action: () => ctx.service.deleteBlueprint(blueprintId),
    onError: ctx.toasts.error,
    onDone: () {
      ctx.toasts.success('Deleted.');
      ctx.router.go(Routes.library);
    },
    confirmLabel: 'Delete',
  );

  // --- Assignment -----------------------------------------------------------

  /// Assigning to a whole role at once is the point of a fleet, and also the
  /// way to get it badly wrong — so it is done in two steps. Preview names
  /// every node it matched; Assign acts on that list, not on the label box, so
  /// what was confirmed is what happens.
  void _renderAssign() {
    clearChildren(_assignBody);
    if (!ctx.auth.state.value.canOperate) {
      _assignBody.appendChild(
        el(
          'div',
          classes: 'hint',
          text: 'Your roles do not permit assigning a blueprint.',
        ),
      );
      return;
    }

    late final web.HTMLInputElement label;
    label = input(
      id: 'assign-label',
      placeholder: 'role=build',
      autocapitalize: 'off',
      onEnter: () => _preview(label.value),
    );

    _assignBody
      ..appendChild(el('h2', text: 'Assign'))
      ..appendChild(
        el(
          'div',
          classes: 'row',
          children: [
            label,
            button('Preview', onClick: () => _preview(label.value)),
          ],
        ),
      )
      ..appendChild(_selectorsBody)
      ..appendChild(_matchesBody)
      ..appendChild(
        el(
          'div',
          classes: 'hint',
          text:
              'Assigning declares what these nodes should be. Nothing runs — '
              'reconcile each node to apply it.',
        ),
      );

    unawaited(_loadSelectors(label));
  }

  /// What the fleet actually calls itself, under the input that asks for it.
  ///
  /// A label selector is free text against labels somebody else set months ago
  /// on a machine you may never have seen, and the failure it invites is not a
  /// typo — a typo matches nothing and is obvious. It is `role=web` on a fleet
  /// that says `tier=web`, matching nothing while looking entirely reasonable.
  /// So the selectors are read off the fleet rather than remembered, each with
  /// how many nodes carry it, and picking one fills the box and previews.
  Future<void> _loadSelectors(web.HTMLInputElement label) async {
    try {
      final nodes = await ctx.service.listNodes();
      if (_disposed) return;

      final counts = <String, int>{};
      for (final node in nodes) {
        for (final entry in node.labels.entries) {
          final selector = '${entry.key}=${entry.value}';
          counts[selector] = (counts[selector] ?? 0) + 1;
        }
      }

      clearChildren(_selectorsBody);
      if (counts.isEmpty) {
        // Not an error. A fleet with no labels is assigned node by node from
        // each node's own page, and saying so beats an empty strip.
        _selectorsBody.appendChild(
          el(
            'div',
            classes: 'hint',
            text: nodes.isEmpty
                ? 'No nodes are registered yet.'
                : 'No node carries a label. Leave the box empty to match the '
                      'whole fleet, or assign from a node’s own page.',
          ),
        );
        return;
      }

      final sorted = counts.keys.toList()..sort();
      _selectorsBody.appendChild(
        el(
          'div',
          classes: 'row wrap',
          children: [
            el('div', classes: 'muted', text: 'in this fleet:'),
            for (final selector in sorted)
              el(
                'span',
                classes: 'badge link mono',
                text: '$selector (${counts[selector]})',
                onClick: (_) {
                  label.value = selector;
                  _preview(selector);
                },
              ),
          ],
        ),
      );
    } on AppError {
      // The box still works, and typing a selector is the primary path. A
      // failed convenience should not put an error banner over a panel that is
      // otherwise fine.
      if (!_disposed) clearChildren(_selectorsBody);
    }
  }

  void _preview(String label) {
    final selector = label.trim();
    clearChildren(_matchesBody);
    _matchesBody.appendChild(loadingRow('Matching…'));
    unawaited(() async {
      try {
        // An empty selector is the whole fleet, which is a real and deliberate
        // thing to want — and exactly why the list is shown before anything is
        // assigned.
        final nodes = await ctx.service.listNodes(
          labels: selector.isEmpty ? const [] : [selector],
        );
        if (_disposed) return;
        _matches = nodes;
        clearChildren(_matchesBody);
        if (nodes.isEmpty) {
          _matchesBody.appendChild(
            emptyState(
              selector.isEmpty
                  ? 'No nodes are registered.'
                  : 'No node matches $selector.',
            ),
          );
          return;
        }
        _matchesBody.appendChild(
          el(
            'div',
            classes: 'row',
            children: [
              el(
                'div',
                classes: 'grow',
                text:
                    'matches ${nodes.length}: '
                    '${nodes.map((n) => n.id.value).join(', ')}',
              ),
              button(
                'Assign to ${nodes.length} node(s)',
                primary: true,
                onClick: _assign,
              ),
            ],
          ),
        );
      } on AppError catch (e) {
        if (_disposed) return;
        clearChildren(_matchesBody);
        _matchesBody.appendChild(errorBanner(e));
      }
    }());
  }

  void _assign() {
    final nodes = _matches;
    if (nodes.isEmpty) return;
    confirmDialog(
      title: 'Assign $blueprintId to ${nodes.length} node(s)?',
      detail:
          'These nodes will be declared to be this blueprint. Any blueprint or '
          'preset already declared for them is replaced. Nothing runs until '
          'each is reconciled.',
      // Named one per line rather than run together in the prose above. This
      // is the last point at which a selector that matched more than its
      // author meant can be noticed, and a comma-separated sentence is exactly
      // the shape a reader skims. Each node carries the labels it matched on,
      // so "why is that one here" is answered without leaving the dialog.
      extra: [
        el(
          'div',
          classes: 'stack',
          children: [
            for (final node in nodes)
              el(
                'div',
                classes: 'row mono',
                children: [
                  el(
                    'span',
                    classes: node.online ? 'badge online' : 'badge offline',
                    text: node.online ? 'online' : 'offline',
                  ),
                  el('div', classes: 'grow', text: node.id.value),
                  el(
                    'div',
                    classes: 'muted ellipsis',
                    text: [
                      for (final label in node.labels.entries)
                        '${label.key}=${label.value}',
                    ].join(' '),
                  ),
                ],
              ),
          ],
        ),
        // An offline node is not a problem — declaring runs nothing — but it
        // is worth saying so, since the badge above invites the question.
        if (nodes.any((n) => !n.online))
          el(
            'div',
            classes: 'hint',
            text:
                'An offline node can still be declared; it is only reconciling '
                'that needs it reachable.',
          ),
      ],
      action: () async {
        // Sequential on purpose: a partial failure should say which node it
        // stopped at, and a fleet-wide fan-out would make that a race.
        for (final node in nodes) {
          await ctx.service.assignBlueprint(node.id.value, blueprintId);
        }
      },
      onError: ctx.toasts.error,
      onDone: () => ctx.toasts.success(
        'Assigned to ${nodes.length} node(s). Nothing has run.',
      ),
      confirmLabel: 'Assign',
    );
  }

  /// Enough of a digest to compare two by eye, which is all anybody does with
  /// it.
  static String _shortHash(String hash) =>
      hash.length <= 12 ? hash : hash.substring(0, 12);

  @override
  void dispose() {
    _disposed = true;
  }
}
