import 'package:omnyshell_web/client.dart' show ThemeMode;
import 'package:omnyshell_web/ui_kit.dart';

import '../app/app_context.dart';

/// Opens the settings modal: the theme, and the AI-agent configuration behind
/// the terminal `:ai` command.
///
/// The AI controls are [aiSettingsSection] from `omnyshell_web` — the same
/// widget the OmnyShell dashboard uses — so the two configure the agent
/// identically.
void showOmnyServerSettings(AppContext ctx) {
  final theme = radioGroup(
    name: 'theme',
    ariaLabel: 'Theme',
    inline: true,
    selected: ctx.theme.mode.value.name,
    options: const [
      (value: 'system', label: 'System'),
      (value: 'light', label: 'Light'),
      (value: 'dark', label: 'Dark'),
    ],
    onChange: (value) => ctx.theme.set(ThemeMode.parse(value)),
  );

  late final Modal modal;
  final body = el(
    'div',
    classes: 'stack settings-panel',
    children: [
      el('h3', text: 'Theme'),
      theme,
      el('hr'),
      ...aiSettingsSection(ctx.ai),
    ],
  );

  modal = Modal(
    title: 'Settings',
    body: body,
    actions: [button('Close', primary: true, onClick: () => modal.close())],
  );
  modal.show();
}
