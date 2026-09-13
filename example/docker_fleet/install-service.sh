#!/bin/sh
# Installs this container's role as a systemd service, at boot, once.
#
# This is where the Hub and node flags live in the service-managed fleet.
# They cannot live in compose.yaml there: systemd is PID 1, so the container's
# command belongs to init, not to OmnyServer. `compose.service.yaml` passes the
# few things that differ per container (ROLE, NODE_ID, NODE_LABELS) and this
# script holds the rest — which keeps the flags in one readable place rather
# than smeared across environment variables.
set -e

# systemd does not hand the container's environment to the units it starts —
# a unit gets a clean one, by design. Docker did give it to PID 1, though, and
# that is readable, so this is where `ROLE` and friends come from. Read rather
# than eval'd, so a label with a space in it survives.
container_env() {
  tr '\0' '\n' < /proc/1/environ | sed -n "s/^$1=//p" | head -1
}

ROLE="${ROLE:-$(container_env ROLE)}"
NODE_ID="${NODE_ID:-$(container_env NODE_ID)}"
NODE_LABELS="${NODE_LABELS:-$(container_env NODE_LABELS)}"

# The Hub issues the fleet's certificate on first boot, into the volume the
# others mount read-only. Issued once and kept: a new CA on every start would
# break every node that already trusts this one.
if [ "$ROLE" = "hub" ] && [ ! -f /certs/server.crt ]; then
  omnyserver cert gen --out /certs --host hub
fi

case "$ROLE" in
  hub)
    omnyserver service install hub --system \
      --host=0.0.0.0 \
      --port=8443 \
      --cert=/certs/server.crt \
      --key=/certs/server.key \
      --grant=node-account:node-token:node \
      --grant=alice:admin-token:admin \
      --api-token=api-secret \
      --data-dir=/data \
      --alert='disk>90' \
      --alert='offline for 30s' \
      --cors-origin=http://localhost:8080 \
      --shell
    ;;

  node)
    # ${NODE_LABELS} is deliberately unquoted: it carries several --label flags.
    # shellcheck disable=SC2086
    omnyserver service install node --system \
      --hub=wss://hub:8443 \
      --id="$NODE_ID" \
      --principal=node-account \
      --token=node-token \
      --ca=/certs/ca.crt \
      --with-shell \
      --data-dir=/var/lib/omnyserver \
      ${NODE_LABELS}
    ;;

  *)
    echo "set ROLE to hub or node (got \"$ROLE\")" >&2
    exit 1
    ;;
esac

# What a server operator would run next, and can run here too:
#   docker compose -f example/docker_fleet/compose.service.yaml exec hub \
#     omnyserver service info hub
omnyserver service info "$ROLE"
