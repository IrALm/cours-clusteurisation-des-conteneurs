#!/usr/bin/env sh
# Interroge l'API en continu et compte les erreurs.
# Usage : ./scripts/curl-loop.sh [http://localhost:8080]
URL="${1:-http://localhost:8080}/api/version"
ok=0; ko=0
trap 'echo; echo "TOTAL ok=$ok ko=$ko"; exit 0' INT
while true; do
  out=$(curl -s -m 2 -w ' %{http_code}' "$URL")
  code=${out##* }
  if [ "$code" = "200" ]; then ok=$((ok+1)); else ko=$((ko+1)); fi
  printf '%s  %s  (ok=%d ko=%d)\n' "$(date +%T)" "$out" "$ok" "$ko"
  sleep 0.2
done
