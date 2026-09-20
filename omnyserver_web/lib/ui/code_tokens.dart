/// Colouring a blueprint or a preset, in whichever language it was written in.
///
/// Hand-written rather than pulled from a highlighting library, for two
/// reasons. The dashboard ships as one `main.dart.js` served from a container
/// or from Pages with no CDN in front of it, so a library would have to be
/// vendored and would dwarf what it is being asked to do; and there are exactly
/// two grammars here, both small, both fully known — a blueprint's YAML and a
/// preset's JSON.
///
/// These are *tokenizers*, not parsers. They never fail, never throw, and never
/// reorder: whatever comes in — a half-typed line, an unterminated string, a
/// document the parser would refuse — is covered by tokens whose text
/// concatenates back to the input exactly. The editor paints this on every
/// keystroke, so "the document is mid-edit and invalid" is the normal case and
/// not the exception.
///
/// Free of `package:web` on purpose, so the scanning is unit-testable on the
/// VM. Turning these into DOM is `highlightedCode` in `widgets.dart`.
library;

import 'package:omnyserver/omnyserver_client_web.dart' show BlueprintFormat;

/// A run of source text, and the class it should be painted with.
///
/// A null [className] is ordinary text that needs no span of its own —
/// whitespace, punctuation the grammar does not care about — which keeps the
/// node count down on a document of any size.
typedef CodeToken = ({String? className, String text});

/// A mapping key.
const String tokenKey = 'tok-key';

/// A string, or a YAML plain scalar being used as a value.
const String tokenString = 'tok-str';

/// A number.
const String tokenNumber = 'tok-num';

/// `true`, `false`, `null` and the YAML spellings of them.
const String tokenLiteral = 'tok-lit';

/// A comment. YAML only — JSON has none, whatever people wish.
const String tokenComment = 'tok-com';

/// Structural punctuation: braces, brackets, colons, commas, list markers.
const String tokenPunct = 'tok-punct';

/// Splits [text] into painted runs, read as [format].
///
/// The concatenation of every token's text equals [text]. That property is what
/// makes this safe to render behind a textarea, where a single dropped or
/// duplicated character would slide the highlighting out of alignment with
/// everything the author types after it.
List<CodeToken> tokenizeCode(String text, BlueprintFormat format) {
  final out = _Tokens();
  switch (format) {
    case BlueprintFormat.yaml:
      _scanYaml(text, out);
    case BlueprintFormat.json:
      _scanJson(text, out);
  }
  return out.done();
}

/// Accumulates runs, merging neighbours that share a class.
class _Tokens {
  final List<CodeToken> _tokens = [];
  final StringBuffer _pending = StringBuffer();
  String? _className;

  void add(String? className, String text) {
    if (text.isEmpty) return;
    if (className != _className) {
      _flush();
      _className = className;
    }
    _pending.write(text);
  }

  void _flush() {
    if (_pending.isEmpty) return;
    _tokens.add((className: _className, text: _pending.toString()));
    _pending.clear();
  }

  List<CodeToken> done() {
    _flush();
    return _tokens;
  }
}

// --- JSON --------------------------------------------------------------------

void _scanJson(String text, _Tokens out) {
  var i = 0;
  while (i < text.length) {
    final c = text[i];

    if (c == '"') {
      final end = _endOfJsonString(text, i);
      // A string is a key when a colon follows it. Nothing else distinguishes
      // the two, and telling them apart is most of what makes JSON readable.
      out.add(
        _colonFollows(text, end) ? tokenKey : tokenString,
        text.substring(i, end),
      );
      i = end;
      continue;
    }

    if (_isDigit(c) ||
        (c == '-' && i + 1 < text.length && _isDigit(text[i + 1]))) {
      final end = _endOfNumber(text, i);
      out.add(tokenNumber, text.substring(i, end));
      i = end;
      continue;
    }

    final literal = _literalAt(text, i);
    if (literal != null) {
      out.add(tokenLiteral, literal);
      i += literal.length;
      continue;
    }

    if (_jsonPunct.contains(c)) {
      out.add(tokenPunct, c);
      i++;
      continue;
    }

    out.add(null, c);
    i++;
  }
}

const String _jsonPunct = '{}[]:,';
const List<String> _jsonLiterals = ['true', 'false', 'null'];

String? _literalAt(String text, int at) {
  for (final word in _jsonLiterals) {
    if (!text.startsWith(word, at)) continue;
    final after = at + word.length;
    if (after < text.length && _isWordChar(text[after])) continue;
    return word;
  }
  return null;
}

/// The index just past the closing quote — or the end of [text] if the string
/// was never closed, which is what a half-typed document looks like.
int _endOfJsonString(String text, int from) {
  var i = from + 1;
  while (i < text.length) {
    final c = text[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    i++;
    if (c == '"') return i;
  }
  return text.length;
}

int _endOfNumber(String text, int from) {
  var i = from + 1;
  while (i < text.length && _isNumberChar(text[i])) {
    i++;
  }
  return i;
}

bool _colonFollows(String text, int at) {
  var i = at;
  while (i < text.length && _isSpace(text[i])) {
    i++;
  }
  return i < text.length && text[i] == ':';
}

// --- YAML --------------------------------------------------------------------

/// A line ending in `|` or `>` opens a block scalar: every following line
/// indented past it is literal text, however much it looks like YAML. Without
/// this a shell script embedded in a `params` value paints as a wall of keys.
final RegExp _blockOpener = RegExp(r'[|>][-+0-9]*\s*(#.*)?$');

void _scanYaml(String text, _Tokens out) {
  final lines = text.split('\n');
  int? blockIndent;
  // Carried across lines, because a flow collection may be written over
  // several of them.
  var flow = 0;

  for (var n = 0; n < lines.length; n++) {
    final line = lines[n];
    if (n > 0) out.add(null, '\n');

    if (blockIndent != null) {
      // A blank line belongs to the block whatever its indentation, since it
      // has none to speak of.
      if (line.trim().isEmpty) {
        out.add(null, line);
        continue;
      }
      if (_indentOf(line) > blockIndent) {
        out.add(tokenString, line);
        continue;
      }
      blockIndent = null;
    }

    final result = _scanYamlLine(line, out, flow);
    flow = result.flow;
    if (result.opensBlock) blockIndent = _indentOf(line);
  }
}

/// Paints one line; answers whether it opened a block scalar, and how deep in
/// flow collections it left off.
({bool opensBlock, int flow}) _scanYamlLine(
  String line,
  _Tokens out,
  int flow,
) {
  var i = 0;

  // Indentation, then however many block-sequence markers the line carries —
  // `- - a` is two nested sequences, and both dashes are structure.
  while (i < line.length && line[i] == ' ') {
    i++;
  }
  out.add(null, line.substring(0, i));
  while (i < line.length &&
      line[i] == '-' &&
      (i + 1 == line.length || line[i + 1] == ' ')) {
    out.add(tokenPunct, '-');
    i++;
    final from = i;
    while (i < line.length && line[i] == ' ') {
      i++;
    }
    out.add(null, line.substring(from, i));
  }

  while (i < line.length) {
    final c = line[i];

    // A `#` only starts a comment at the beginning of a token, which is why
    // `web-server#1` stays one scalar.
    if (c == '#' && (i == 0 || line[i - 1] == ' ')) {
      out.add(tokenComment, line.substring(i));
      return (opensBlock: false, flow: flow);
    }

    if (c == ' ') {
      final from = i;
      while (i < line.length && line[i] == ' ') {
        i++;
      }
      out.add(null, line.substring(from, i));
      continue;
    }

    if (c == '"' || c == "'") {
      final end = _endOfYamlQuoted(line, i);
      out.add(
        _isKeySeparatorAfter(line, end) ? tokenKey : tokenString,
        line.substring(i, end),
      );
      i = end;
      continue;
    }

    if (_yamlPunct.contains(c)) {
      if (c == '{' || c == '[') flow++;
      if ((c == '}' || c == ']') && flow > 0) flow--;
      out.add(tokenPunct, c);
      i++;
      continue;
    }

    final end = _endOfPlain(line, i, flow);
    if (end == i) {
      // Unreachable given the branches above, and cheap insurance against the
      // one bug a scanner must never have.
      out.add(null, c);
      i++;
      continue;
    }

    final run = line.substring(i, end);
    final trimmed = run.trimRight();
    // A run that stopped on a `key:` separator is a key; anything else is a
    // value, and a plain scalar reads best coloured as the string it is.
    out.add(
      i + trimmed.length == end && _isColonSeparator(line, end)
          ? tokenKey
          : _classifyPlain(trimmed),
      trimmed,
    );
    out.add(null, run.substring(trimmed.length));
    i = end;
  }

  return (opensBlock: _blockOpener.hasMatch(line), flow: flow);
}

const String _yamlPunct = '{}[],:';

const Set<String> _yamlLiterals = {
  'true',
  'false',
  'null',
  'yes',
  'no',
  'on',
  'off',
  '~',
};

final RegExp _yamlNumber = RegExp(r'^[-+]?(\d[\d_]*)(\.\d*)?([eE][-+]?\d+)?$');

String _classifyPlain(String value) {
  if (value.isEmpty) return tokenString;
  if (_yamlNumber.hasMatch(value)) return tokenNumber;
  if (_yamlLiterals.contains(value.toLowerCase())) return tokenLiteral;
  return tokenString;
}

/// Where a plain scalar ends: at a flow indicator, at a ` #` comment, or at the
/// `:` that makes what came before it a key.
///
/// `,`, `}` and `]` only end one *inside* a flow collection ([flow] > 0). In
/// block context they are ordinary characters, and treating them otherwise
/// chops an English sentence in half at its first comma — which is what a
/// blueprint's `description` usually is.
int _endOfPlain(String line, int from, int flow) {
  var i = from;
  while (i < line.length) {
    final c = line[i];
    if (c == '{' || c == '[') break;
    if (flow > 0 && (c == ',' || c == '}' || c == ']')) break;
    if (c == '#' && i > from && line[i - 1] == ' ') break;
    if (c == ':' && _isColonSeparator(line, i)) break;
    i++;
  }
  return i;
}

/// Whether the `:` at [at] separates a key from a value, rather than merely
/// sitting inside one — `https://hub` is a scalar, `name: hub` is a pair.
bool _isColonSeparator(String line, int at) {
  if (at >= line.length || line[at] != ':') return false;
  final after = at + 1;
  if (after >= line.length) return true;
  final c = line[after];
  return c == ' ' || c == ',' || c == '}' || c == ']';
}

/// The same question, asked from just past a quoted scalar, where spaces may
/// sit between it and its colon.
bool _isKeySeparatorAfter(String line, int at) {
  var i = at;
  while (i < line.length && line[i] == ' ') {
    i++;
  }
  return _isColonSeparator(line, i);
}

/// The index just past the closing quote, honouring `''` inside single quotes
/// and backslash escapes inside double ones — or the end of the line, since a
/// scalar being typed is not yet closed.
int _endOfYamlQuoted(String line, int from) {
  final quote = line[from];
  var i = from + 1;
  while (i < line.length) {
    final c = line[i];
    if (quote == '"' && c == r'\') {
      i += 2;
      continue;
    }
    if (c == quote) {
      if (quote == "'" && i + 1 < line.length && line[i + 1] == "'") {
        i += 2;
        continue;
      }
      return i + 1;
    }
    i++;
  }
  return line.length;
}

int _indentOf(String line) {
  var i = 0;
  while (i < line.length && line[i] == ' ') {
    i++;
  }
  return i;
}

// --- Character tests ---------------------------------------------------------

bool _isDigit(String c) => c.compareTo('0') >= 0 && c.compareTo('9') <= 0;

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

bool _isNumberChar(String c) =>
    _isDigit(c) || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-';

bool _isWordChar(String c) =>
    _isDigit(c) || c == '_' || (c.toLowerCase() != c.toUpperCase());
