/// The handful of widgets the shared kit does not have.
///
/// `omnyshell_web`'s `ui_kit` covers everything a form needs except a multi-line
/// input, and it has no opinion about confirmation — so these four live here,
/// in one place, rather than being reinvented per screen. Each of them was
/// already duplicated across two screens before it moved here.
library;

import 'dart:js_interop';

import 'package:omnyserver/omnyserver_client_web.dart' show BlueprintFormat;
import 'package:omnyshell_web/foundation.dart' show AppError;
import 'package:omnyshell_web/ui_kit.dart';
import 'package:web/web.dart' as web;

import 'code_tokens.dart';

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

/// [text] painted as [format], for reading.
web.HTMLElement highlightedCode(String text, BlueprintFormat format) => el(
  'pre',
  classes: 'screen-capture',
  children: [
    el(
      'code',
      children: [
        for (final token in tokenizeCode(text, format))
          if (token.className case final className?)
            el('span', classes: className, text: token.text)
          else
            textNode(token.text),
      ],
    ),
  ],
);

/// An editor that paints the document underneath the caret.
///
/// A transparent textarea over a `<pre>` carrying the same text in spans: the
/// browser keeps doing selection, undo, spell-check suppression, mobile
/// keyboards and accessibility, and the only job left is keeping the two in
/// step. They share one set of metrics in `app.css` for that reason — a font or
/// a padding that differs between them slides the colour off the characters.
///
/// Neither wraps (`white-space: pre`), which is deliberate twice over:
/// indentation carries meaning in YAML and a wrapped line hides it, and a
/// scrollbar appearing in the textarea would otherwise narrow it and re-wrap
/// its text while the layer underneath kept the old wrap points.
({web.HTMLElement root, web.HTMLTextAreaElement input}) codeEditor({
  required String id,
  required String value,
  required BlueprintFormat format,
  int rows = 20,
}) {
  final input = textarea(id: id, value: value, rows: rows);
  input.className = 'code-input';
  input.setAttribute('wrap', 'off');

  final layer = el(
    'pre',
    classes: 'code-layer',
    // It is the textarea that carries the content for a screen reader; this is
    // the same text again, in colour.
    attrs: {'aria-hidden': 'true'},
  );

  void paint() {
    clearChildren(layer);
    // A trailing newline has no line of its own to give the layer height, so
    // the last line would sit a row above the caret. One more newline, and the
    // two end at the same place.
    final text = input.value.endsWith('\n') ? '${input.value}\n' : input.value;
    for (final token in tokenizeCode(text, format)) {
      layer.appendChild(
        token.className == null
            ? textNode(token.text)
            : el('span', classes: token.className, text: token.text),
      );
    }
  }

  paint();
  on(input, 'input', (_) => paint());
  on(input, 'scroll', (_) {
    layer.scrollTop = input.scrollTop;
    layer.scrollLeft = input.scrollLeft;
  });

  return (
    root: el('div', classes: 'code-editor', children: [layer, input]),
    input: input,
  );
}

/// Stops a click on [element] from reaching the row around it.
///
/// A list row that navigates cannot also hold a button without this: the
/// button runs, and then the row opens the thing the button was acting on.
web.HTMLElement stopClickPropagation(web.HTMLElement element) {
  element.addEventListener('click', _swallowClick);
  return element;
}

final _swallowClick = ((web.Event event) => event.stopPropagation()).toJS;

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
