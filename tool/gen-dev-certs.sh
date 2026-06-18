#!/bin/bash
# Generate local dev TLS certificates (CA + Hub server cert) into certs/.
#
# Creates a CA -> leaf chain because Dart's TLS stack rejects a bare
# self-signed leaf used as its own trust anchor. The CA carries keyCertSign;
# the leaf carries serverAuth.
#
# Usage: tool/gen-dev-certs.sh [extra-host]
# No-op once certs/server.crt exists; delete certs/ to regenerate.
set -euo pipefail

OUT="${OMNYSERVER_CERT_DIR:-certs}"
EXTRA_HOST="${1:-}"

if [ -f "$OUT/server.crt" ]; then
  echo "certs already present in $OUT/ (delete to regenerate)"
  exit 0
fi

dart run bin/omnyserver.dart cert gen --out "$OUT" ${EXTRA_HOST:+--host "$EXTRA_HOST"}
