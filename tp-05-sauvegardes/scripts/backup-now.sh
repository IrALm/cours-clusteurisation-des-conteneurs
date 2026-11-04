#!/bin/sh
# Sauvegarde À LA DEMANDE : tâche ponctuelle pg_dump dans le volume quickpoll_backups.
# Usage (sur le manager) : scripts/backup-now.sh [nom]   -> /backups/<nom>.dump
set -eu
NAME="${1:-manual-$(date +%Y%m%d-%H%M%S)}"
docker service rm backup-now >/dev/null 2>&1 || true
docker service create --detach --name backup-now --mode replicated-job \
  --network quickpoll_back --secret db_password \
  --constraint node.labels.backup==true \
  --mount type=volume,source=quickpoll_backups,target=/backups \
  postgres:17-alpine sh -c "export PGPASSWORD=\"\$(cat /run/secrets/db_password)\";
    pg_dump -h db -U quickpoll -d quickpoll -Fc -f /backups/$NAME.dump.tmp &&
    mv /backups/$NAME.dump.tmp /backups/$NAME.dump && echo saved /backups/$NAME.dump" >/dev/null
# attendre la fin du job
until docker service ps backup-now --format '{{.CurrentState}}' | grep -qE '^(Complete|Failed|Rejected)'; do sleep 1; done
docker service ps backup-now --format '{{.Node}} {{.CurrentState}} {{.Error}}'
docker service logs --raw backup-now
docker service rm backup-now >/dev/null
