/// OmnyServer CLI as a library: the `CommandRunner`, individual commands and a
/// REST client for the Hub API.
///
/// Every command is a thin wrapper over the public runtimes and the Hub HTTP
/// API, so anything the CLI does is equally reachable programmatically.
library;

export 'omnyserver.dart';

export 'src/cli/api_client.dart';
// The VM's HTTP transport, and where the TLS knobs live — a browser owns its own
// TLS stack, so they cannot sit on the client itself.
export 'src/cli/api_transport.dart';
export 'src/cli/api_transport_io.dart';
export 'src/cli/ai_command.dart';
export 'src/cli/cli.dart';
export 'src/cli/service_commands.dart';
export 'src/cli/start_options.dart';
