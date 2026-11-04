#!/bin/sh
# QuickPoll backup: one pg_dump every $INTERVAL seconds, keeps the $KEEP latest files.
set -u
export PGPASSWORD="$(cat /run/secrets/db_password)"
while true; do
  file="/backups/quickpoll-$(date +%Y%m%d-%H%M%S).dump"
  if pg_dump -h db -U quickpoll -d quickpoll -Fc -f "$file.tmp"; then
    mv "$file.tmp" "$file" && echo "$(date +%T) saved $file ($(du -h "$file" | cut -f1))"
  else
    rm -f "$file.tmp"; echo "$(date +%T) backup FAILED"
  fi
  ls -1t /backups/*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
  sleep "$INTERVAL"
done
