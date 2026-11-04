#!/bin/sh
# Envoie N votes (défaut 10) et affiche le code HTTP de chacun.
# Usage : scripts/vote.sh 5 [http://quickpoll.localhost:8080]
N="${1:-10}"; BASE="${2:-http://quickpoll.localhost:8080}"
i=0; ok=0
while [ "$i" -lt "$N" ]; do
  case $((i % 3)) in 0) o=swarm;; 1) o=kubernetes;; *) o=nomad;; esac
  code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST -d "{\"option\":\"$o\"}" "$BASE/api/vote")
  [ "$code" = "201" ] && ok=$((ok+1))
  i=$((i+1))
done
echo "$(date +%T) votes envoyés=$N acceptés=$ok"
curl -s "$BASE/api/poll"; echo
