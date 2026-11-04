#!/bin/sh
# Interroge une URL en boucle (5 req/s) et affiche l'heure, le code HTTP et le total des votes.
# Le code 000 signifie « pas de réponse » (timeout / connexion refusée).
# Usage : scripts/hammer.sh http://quickpoll.localhost:8080/api/poll
URL="${1:-http://quickpoll.localhost:8080/api/poll}"
ok=0; ko=0; last=""
trap 'echo; echo "TOTAL ok=$ok ko=$ko"; exit 0' INT TERM
while true; do
  out=$(curl -s -m 2 -w ' %{http_code}' "$URL")
  code=${out##* }
  total=$(printf '%s' "$out" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')
  if [ "$code" = "200" ]; then ok=$((ok+1)); else ko=$((ko+1)); fi
  # une ligne à chaque changement d'état, plus une ligne toutes les 25 requêtes
  state="$code ${total:--}"
  if [ "$state" != "$last" ] || [ $(((ok+ko) % 25)) -eq 0 ]; then
    printf '%s  %s  total=%s  (ok=%d ko=%d)\n' "$(date +%T)" "$code" "${total:--}" "$ok" "$ko"
    last="$state"
  fi
  sleep 0.2
done
