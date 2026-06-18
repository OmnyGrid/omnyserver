#!/bin/bash
# Start a local OmnyServer Hub (WSS + HTTP API) with dev certs and demo grants.
#
# Usage: ./run-hub.sh
# Override with env vars: OMNYSERVER_HOST, OMNYSERVER_PORT, OMNYSERVER_API_PORT,
# OMNYSERVER_CERT, OMNYSERVER_KEY, OMNYSERVER_GRANT, OMNYSERVER_API_TOKEN.
set -euo pipefail

HOST="${OMNYSERVER_HOST:-127.0.0.1}"
PORT="${OMNYSERVER_PORT:-8443}"
API_PORT="${OMNYSERVER_API_PORT:-8080}"
CERT="${OMNYSERVER_CERT:-certs/server.crt}"
KEY="${OMNYSERVER_KEY:-certs/server.key}"
API_TOKEN="${OMNYSERVER_API_TOKEN:-api-secret}"

# Demo grants: "principal:token:roles" (space-separated for multiple).
GRANTS="${OMNYSERVER_GRANT:-alice:admin-token:admin node-account:node-token:node}"

if [ ! -f "$CERT" ]; then
  echo "Generating dev certificates..."
  tool/gen-dev-certs.sh
fi

dart pub get

GRANT_ARGS=()
for g in $GRANTS; do
  GRANT_ARGS+=(--grant "$g")
done

exec dart run bin/omnyserver.dart hub start \
  --host "$HOST" --port "$PORT" \
  --cert "$CERT" --key "$KEY" \
  --api-port "$API_PORT" --api-token "$API_TOKEN" \
  "${GRANT_ARGS[@]}"
