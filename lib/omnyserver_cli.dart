/// OmnyServer CLI as a library: the `CommandRunner`, individual commands and a
/// REST client for the Hub API.
///
/// Every command is a thin wrapper over the public runtimes and the Hub HTTP
/// API, so anything the CLI does is equally reachable programmatically.
library;

export 'omnyserver.dart';

export 'src/cli/api_client.dart';
export 'src/cli/cli.dart';
