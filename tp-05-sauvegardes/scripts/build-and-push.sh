#!/bin/sh
# Construit les images QuickPoll 1.0 et les pousse dans le registry du cluster.
set -eu
REGISTRY="${REGISTRY:-127.0.0.1:5000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
docker build -q -t "$REGISTRY/quickpoll-api:1.0"   "$ROOT/app/api"   && docker push -q "$REGISTRY/quickpoll-api:1.0"
docker build -q -t "$REGISTRY/quickpoll-front:1.0" "$ROOT/app/front" && docker push -q "$REGISTRY/quickpoll-front:1.0"
