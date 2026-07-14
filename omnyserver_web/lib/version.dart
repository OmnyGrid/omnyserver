import 'package:omnyserver/omnyserver_client_web.dart' show omnyServerVersion;

/// The dashboard's version, kept in sync with `pubspec.yaml` by a test.
///
/// The Pages deploy builds against the server in this repo, so this and
/// [omnyServerVersion] always move together.
const String omnyServerWebVersion = '0.2.2';

/// The one version line shown in the UI: this dashboard build, and the
/// OmnyServer version it was built against.
///
/// Both are compile-time — the login screen is not connected to a Hub yet — so
/// this names the API the dashboard *targets*, not the version of whichever Hub
/// you sign in to. Composed here so every place that shows it reads the same.
String get versionLabel =>
    'Dashboard v$omnyServerWebVersion · OmnyServer v$omnyServerVersion';
