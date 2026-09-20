/// The handful of widgets the shared kit does not have.
///
/// `omnyshell_web`'s `ui_kit` covers everything a form needs except a multi-line
/// input, and it has no opinion about confirmation — so these four live here,
/// in one place, rather than being reinvented per screen. Each of them was
/// already duplicated across two screens before it moved here.
library;

import 'package:omnyshell_web/foundation.dart' show AppError;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

/// A multi-line text input.
///
/// The kit styles `input` and `select` but has no textarea helper, so
/// `web/app.css` carries the matching rule. Returns the element, like
/// [input] does, so callers read `.value` back off it.
web.HTMLTextAreaElement textarea({
  required String id,
  String? value,
  String? placeholder,
  int rows = 16,
}) {
  final e = el('textarea', id: id) as web.HTMLTextAreaElement;
  e.rows = rows;
  if (value != null) e.value = value;
  if (placeholder != null) e.placeholder = placeholder;
  // A blueprint is whitespace-significant YAML typed by hand; the browser's
  // spellchecker underlining every identifier in it is noise.
  e.spellcheck = false;
  e.setAttribute('autocorrect', 'off');
  e.autocapitalize = 'off';
  return e;
}

/// A `<select>` over [options], each a `(value, label)` pair.
web.HTMLSelectElement select({
  required String id,
  required List<({String value, String label})> options,
  String? selected,
}) {
  final e = el('select', id: id) as web.HTMLSelectElement;
  for (final option in options) {
    final node = el('option', text: option.label) as web.HTMLOptionElement;
    node.value = option.value;
    e.appendChild(node);
  }
  if (selected != null) e.value = selected;
  return e;
}

/// A label/value list — a fixed label column so the values line up.
web.HTMLElement facts(Map<String, String> entries) => el(
  'div',
  classes: 'stack',
  children: [
    for (final f in entries.entries)
      el(
        'div',
        classes: 'row',
        children: [
          el('div', classes: 'muted', text: f.key),
          el('div', classes: 'grow ellipsis', text: f.value),
        ],
      ),
  ],
);

/// Asks before doing something that cannot be taken back.
///
/// Every fleet-changing action is confirmed: these are not undoable, and a
/// misplaced click shuts down a machine. [extra] is for the choices a
/// particular action needs — the checkboxes on a purge, say — and is laid out
/// under [detail]; read the boxes inside [action], which only runs on Confirm.
///
/// [action] reports through [onError] / [onDone] rather than throwing into the
/// click handler, so a failure lands in a toast instead of the console.
void confirmDialog({
  required String title,
  required String detail,
  required Future<void> Function() action,
  required void Function(String message) onError,
  required void Function() onDone,
  List<web.HTMLElement> extra = const [],
  String confirmLabel = 'Confirm',
}) {
  late final Modal modal;
  modal = Modal(
    title: title,
    body: el(
      'div',
      classes: 'stack',
      children: [
        el('div', text: detail),
        ...extra,
      ],
    ),
    actions: [
      button('Cancel', onClick: () => modal.close()),
      button(
        confirmLabel,
        primary: true,
        onClick: () async {
          // Closed first, so the checkboxes are read before the dialog goes —
          // they are read inside [action], and the DOM nodes outlive the
          // overlay either way.
          modal.close();
          try {
            await action();
            onDone();
          } on AppError catch (e) {
            onError(e.message);
          }
        },
      ),
    ],
  );
  modal.show();
}
