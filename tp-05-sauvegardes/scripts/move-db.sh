#!/bin/sh
# Déménage la base QuickPoll d'un nœud à un autre SANS perdre de vote.
# Usage (sur le manager, depuis le dossier du TP) : scripts/move-db.sh manager1 worker2
#
#   1. gel des écritures      : api à 0 réplica (plus aucun vote ne peut arriver)
#   2. sauvegarde à la demande: pg_dump -> /backups/move-<date>.dump
#   3. bascule des étiquettes : db=true retirée de FROM, posée sur TO
#   4. attente                : nouvelle tâche db "Running" sur TO (= healthcheck pg_isready OK)
#   5. restauration           : pg_restore de la sauvegarde de l'étape 2
#   6. dégel                  : api remise à 3 réplicas
set -eu
FROM="$1"; TO="$2"; REPLICAS="${REPLICAS:-3}"
DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="move-$(date +%Y%m%d-%H%M%S)"
log() { echo "$(date +%T) | $*"; }

log "début du déménagement $FROM -> $TO"
log "1. gel des écritures (api -> 0)"
docker service scale -d quickpoll_api=0 >/dev/null
until [ -z "$(docker service ps -q quickpoll_api --filter desired-state=running)" ]; do sleep 1; done
# les tâches désirées "shutdown" doivent être réellement arrêtées
while docker service ps quickpoll_api --format '{{.CurrentState}}' | grep -q '^Running'; do sleep 1; done

log "2. sauvegarde à la demande ($NAME.dump)"
sh "$DIR/backup-now.sh" "$NAME"

log "3. bascule des étiquettes"
docker node update --label-rm db "$FROM" >/dev/null
docker node update --label-add db=true "$TO" >/dev/null

log "4. attente d'une base saine sur $TO"
until docker service ps quickpoll_db --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' \
      | grep -q "^$TO Running"; do sleep 1; done
log "   base Running sur $TO"

log "5. restauration de $NAME.dump"
sh "$DIR/restore.sh" "$NAME.dump"

log "6. dégel (api -> $REPLICAS)"
docker service scale -d quickpoll_api="$REPLICAS" >/dev/null
log "fin du déménagement"
