#!/bin/sh
# Restaure une sauvegarde dans la base courante (service quickpoll_db) via une tâche ponctuelle.
# Usage (sur le manager) : scripts/restore.sh            -> dernière sauvegarde
#                          scripts/restore.sh <fichier>  -> ex. manual-20261104-150000.dump
set -eu
FILE="${1:-}"
if [ -n "$FILE" ]; then PICK="f=/backups/$FILE"; else PICK='f=$(ls -1t /backups/*.dump | head -1)'; fi
docker service rm restore >/dev/null 2>&1 || true
docker service create --detach --name restore --mode replicated-job \
  --network quickpoll_back --secret db_password \
  --constraint node.labels.backup==true \
  --mount type=volume,source=quickpoll_backups,target=/backups \
  postgres:17-alpine sh -c "export PGPASSWORD=\"\$(cat /run/secrets/db_password)\";
    $PICK; echo \"restoring \$f\";
    pg_restore -h db -U quickpoll -d quickpoll --clean --if-exists \"\$f\" && echo restore OK" >/dev/null
until docker service ps restore --format '{{.CurrentState}}' | grep -qE '^(Complete|Failed|Rejected)'; do sleep 1; done
docker service ps restore --format '{{.Node}} {{.CurrentState}} {{.Error}}'
docker service logs --raw restore
docker service rm restore >/dev/null
