#!/usr/bin/env sh
# Construit les images QuickPoll et les pousse dans le registry local du cluster.
# À lancer sur le nœud manager, APRÈS avoir créé le service registry (voir README).
set -eu

REGISTRY="${REGISTRY:-127.0.0.1:5000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

build_push() {
  tag="$1"; shift
  echo ">> $REGISTRY/$tag"
  docker build -q -t "$REGISTRY/$tag" "$@"
  docker push -q "$REGISTRY/$tag"
}

build_push quickpoll-front:v1  "$ROOT/app/front"
build_push quickpoll-worker:v1 "$ROOT/app/worker"
build_push quickpoll-api:v1    --build-arg APP_VERSION=v1 "$ROOT/app/api"
build_push quickpoll-api:v2    --build-arg APP_VERSION=v2 "$ROOT/app/api"
build_push quickpoll-api:v3    --build-arg APP_VERSION=v3 --build-arg BREAK_HEALTH=true "$ROOT/app/api"

echo
echo "Images disponibles :"
curl -s "http://$REGISTRY/v2/_catalog"
