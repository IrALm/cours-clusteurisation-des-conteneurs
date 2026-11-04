# TP 5 – Données, sauvegardes et perte du nœud de la base

Date : 04/11/2026

Le but du TP est de voir que Swarm sait relancer le conteneur de la base ailleurs, mais **pas ses données**, puis de mettre en place une sauvegarde automatique sur un autre nœud, de la restaurer, de déménager la base sans perte et enfin de survivre à la perte du nœud de la base en **mesurant** le RPO et le RTO.

Résultats mesurés :

| | Valeur mesurée |
|---|---|
| **RPO** (perte du nœud de la base, étape 6) | **36 s de données = 59 votes perdus** (dernière sauvegarde 15:02:44, dernier vote accepté 15:03:19) |
| **RTO** (étape 6) | **1 min 27 s** (panne 15:03:20 → premier vote accepté 15:04:47), dont 20 s de reprise technique |
| Déménagement planifié (étape 5) | **0 vote perdu**, votes refusés pendant **27 s** |

Fichiers rendus :

| Fichier | Contenu |
|---|---|
| `README.md` | ce compte rendu et le runbook |
| [stack.yml](stack.yml) | la stack : `front`, `api`, `db`, `backup` |
| [backup.sh](backup.sh) | le script de sauvegarde, injecté par une **config** Docker |
| [.gitignore](.gitignore) | exclut les `*.dump` et tout fichier de mot de passe |
| [scripts/backup-now.sh](scripts/backup-now.sh) | sauvegarde à la demande (`replicated-job` `pg_dump`) |
| [scripts/restore.sh](scripts/restore.sh) | restauration (`replicated-job` `pg_restore`), dernière sauvegarde ou fichier choisi |
| [scripts/move-db.sh](scripts/move-db.sh) | déménagement de la base sans perte (étape 5) |
| [scripts/hammer.sh](scripts/hammer.sh) | sonde : interroge une URL 5 fois/s, affiche l'heure et le code HTTP |
| [scripts/vote.sh](scripts/vote.sh) | envoie N votes |
| [app/](app/) | QuickPoll 1.0 (front nginx + API Node) |
| [captures/](captures/) | les sorties de commandes, numérotées dans l'ordre du TP |

---

## 0. Environnement

Comme aux TP précédents, le cluster est en Docker-in-Docker sur mon PC (Windows 11, Docker Desktop) : 3 conteneurs `docker:dind`, avec des **noms d'hôte** `manager1`, `worker1`, `worker2` (ce sont les noms des nœuds Swarm). Les **noms de conteneurs** sont préfixés `tp5-` car `worker1`/`worker2` existaient déjà (cluster du TP 1). La commande du sujet `docker stop worker2` devient donc `docker stop tp5-worker2`.

```bash
docker network create tp5-net
docker run -d --privileged --name tp5-manager1 --hostname manager1 --network tp5-net \
  -p 8080:8080 -v "<chemin de tp-05-sauvegardes>:/tp" docker:dind
docker run -d --privileged --name tp5-worker1 --hostname worker1 --network tp5-net docker:dind
docker run -d --privileged --name tp5-worker2 --hostname worker2 --network tp5-net docker:dind

# dans tp5-manager1
docker swarm init --advertise-addr 172.28.0.2      # puis "docker swarm join" sur les 2 workers
docker service create --name registry --publish 5000:5000 --constraint node.role==manager \
  --mount type=volume,source=registry-data,target=/var/lib/registry registry:2
docker node update --label-add db=true manager1
head -c 24 /dev/urandom | base64 | tr -d '\n' | docker secret create db_password -
cd /tp && sh scripts/build-and-push.sh && docker stack deploy -c stack.yml quickpoll
```

Différences avec le kit du cours, que je n'avais pas (je suis reparti de l'app du TP 2) :

- **Pas de Traefik** : `front` publie directement le port 8080. `http://quickpoll.localhost:8080` marche quand même, car `*.localhost` pointe sur 127.0.0.1.
- **L'API écrit directement dans Postgres** (pas de Redis ni de worker, comme dans la sortie « Vérifier » du sujet). Un vote refusé se voit donc tout de suite (code 503).
- `/api/health` ne teste **que** le processus, pas la base. Sinon, quand la base tombe, Swarm tuerait les 3 API en boucle et `/api/info` ne répondrait plus.
- `/api/info` répond toujours, avec `"db":"up"` ou `"db":"down"`.
- `/api/poll` répond `total: 0` sur une base neuve (table absente). Dans ce cas `/api/vote` **refuse** les votes, parce que la table n'est créée qu'au démarrage de l'API. C'est voulu : un vote écrit dans une base vide serait de toute façon effacé par la restauration (`--clean`).
- La base a un healthcheck `pg_isready`. Dans Swarm, une tâche avec un healthcheck ne passe en `Running` qu'une fois saine : « attendre une base saine », c'est donc attendre `Running`.

**Toutes les heures sont en UTC** (heure des conteneurs ; `hammer.sh` lancé avec `TZ=UTC`). Mon PC est en UTC+1, d'où les heures en 16:xx dans certaines sorties de `vote.sh`.

---

## Étape 1 – Où sont les données ?

([captures/01-ou-sont-les-donnees.txt](captures/01-ou-sont-les-donnees.txt))

```text
[manager1] local     quickpoll_db-data
[worker1]  (rien)
[worker2]  (rien)
Mountpoint : /var/lib/docker/volumes/quickpoll_db-data/_data      (45.8M)
PG_VERSION  base  global  pg_wal  pg_xact  ...  postgresql.conf  postmaster.pid
```

- **Sur quel(s) nœud(s) ?** Uniquement sur `manager1`, le nœud qui porte `db=true` et qui fait tourner la tâche `db`. Un volume `local` est un simple dossier du disque du nœud. Docker le crée **au moment où une tâche qui le monte démarre sur ce nœud**. Le nom `quickpoll_db-data` est le même dans toute la stack, mais chaque nœud aurait son propre dossier. Les workers n'ont jamais exécuté de tâche `db`, donc pas de volume.
- **Contenu du `Mountpoint` :** le répertoire de données de PostgreSQL (`PGDATA`). `base/` contient les fichiers des tables, `pg_wal/` le journal des transactions, plus `postgresql.conf`, `pg_hba.conf`, `PG_VERSION` (17) et `postmaster.pid` (le verrou du serveur en cours d'exécution). Ce sont des fichiers binaires, propres à cette version de Postgres. Les copier à chaud ne donne pas une sauvegarde cohérente.

## Étape 2 – Le déménagement raté

([captures/02-demenagement-rate.txt](captures/02-demenagement-rate.txt))

```text
15:56:41 total avant : 10
$ docker node update --label-rm db manager1 ; docker node update --label-add db=true worker2
quickpoll_db.1      worker2    Running   Running 9 seconds ago
 \_ quickpoll_db.1  manager1   Shutdown  Rejected 25 seconds ago  "assigned node no longer meets…"
total après : {"total":0,"results":[],"schema":"missing"}
volumes : manager1 -> quickpoll_db-data   worker2 -> quickpoll_db-data
2 votes envoyés, 0 acceptés  (relation "votes" does not exist)
# retour de l'étiquette sur manager1
total après retour : 10
```

- **La tâche :** la contrainte `node.labels.db == true` n'est plus vraie sur `manager1`. Swarm arrête la tâche (`Rejected : assigned node no longer meets constraints`) et en crée une nouvelle sur `worker2`, le seul nœud qui convient.
- **Les votes : 0.** Sur `worker2`, Docker a créé un **nouveau** volume `quickpoll_db-data`, vide. Postgres a donc initialisé une base neuve. Il existe maintenant **deux** volumes du même nom, un sur `manager1` (10 votes) et un sur `worker2` (vide). Avec mon API, les votes sont même refusés tant que la table n'existe pas.
- **Retour sur `manager1` : oui, les 10 votes reviennent.** Le volume de `manager1` n'a jamais été effacé. La nouvelle tâche le remonte et retrouve les fichiers de la base. Swarm a déplacé le **processus**, mais les **données** restent attachées au disque du nœud. Si des votes avaient été acceptés sur `worker2`, ils seraient maintenant « perdus » dans le volume de `worker2`.

## Étape 3 – Le service de sauvegarde

Ajouts dans [stack.yml](stack.yml) :

```yaml
  backup:
    image: postgres:17-alpine
    entrypoint: ["/bin/sh", "/backup.sh"]
    environment: { INTERVAL: "60", KEEP: "10" }
    configs:  [{ source: backup_script, target: /backup.sh }]
    secrets:  [db_password]
    volumes:  [backups:/backups]
    networks: [back]
    deploy:
      placement:
        constraints: [node.labels.backup == true]

configs:
  backup_script:
    file: ./backup.sh
```

```bash
docker node update --label-add backup=true manager1
docker stack deploy -c stack.yml quickpoll
```

([captures/03-service-backup.txt](captures/03-service-backup.txt))

```text
14:57:44 saved /backups/quickpoll-20261104-145744.dump (4.0K)
14:58:44 saved /backups/quickpoll-20261104-145844.dump (4.0K)
14:59:44 saved /backups/quickpoll-20261104-145944.dump (4.0K)
; Archive created at 2026-11-04 14:59:44 UTC   dbname: quickpoll   Format: CUSTOM
218; 1259 16386 TABLE public votes quickpoll
217; 1259 16385 SEQUENCE public votes_id_seq quickpoll
3458; 0 16386 TABLE DATA public votes quickpoll
```

Remarque : à ce moment-là, la base est encore sur `manager1`, le même nœud que `backup`. Ce n'est corrigé qu'à l'étape 5, quand la base part sur `worker2`.

- **Pourquoi d'abord `.tmp`, puis renommer ?** `pg_dump` met plusieurs secondes à écrire, et il peut s'arrêter en plein milieu : base qui tombe, conteneur tué par une mise à jour, disque plein. Sans le `.tmp`, il resterait un `quickpoll-….dump` tronqué, et comme la restauration prend « le plus récent » (`ls -1t | head -1`), on restaurerait un fichier cassé. `mv` dans le même système de fichiers est **atomique** : un `.dump` existe complet, ou n'existe pas. En plus, la rotation (`*.dump`) ne compte pas les `.tmp`, et un échec les supprime (`rm -f "$file.tmp"`).
- **Pourquoi un autre nœud ?** Une sauvegarde sur le même disque que la base disparaît avec elle. Si le nœud de la base meurt (panne, disque, VM supprimée), on perd la base **et** ses sauvegardes. L'étape 6 le montre : `worker2` est mort, mais les sauvegardes étaient sur `manager1` et ont permis la reprise sur `worker1`.

## Étape 4 – Une restauration

([captures/04-restauration.txt](captures/04-restauration.txt))

```text
15:00:16  5 votes (lot A)                         -> total 15
15:00:44  saved /backups/quickpoll-20261104-150044.dump
15:00:45  5 votes (lot B)                         -> total 20
$ docker service create --name restore --mode replicated-job ...   (commande du sujet)
restore   replicated job   0/1 (1/1 completed)   postgres:17-alpine
restore.0.q1b3sjsee08o@manager1    | restoring /backups/quickpoll-20261104-150044.dump
total après restauration : 15
```

- **Après la restauration : 15 votes.** Ce sont les 10 votes de départ et le lot A, tous présents dans la sauvegarde de 15:00:44. Les **5 votes du lot B** (ids 16 à 20), arrivés après cette sauvegarde, sont perdus. `--clean --if-exists` supprime la table puis la recrée telle qu'elle était dans le dump, séquence `votes_id_seq` comprise (le prochain id redevient 16).
- **RPO maximal avec une sauvegarde toutes les 60 s : environ 60 s** de votes, plus la durée d'un `pg_dump` (moins d'une seconde ici). C'est le cas d'une panne juste avant la sauvegarde suivante. Mais c'est un minimum théorique : **une sauvegarde qui échoue double le RPO**. Pendant l'étape 5, celle de 15:01:44 a échoué (`could not translate host name "db"`), car la base était en train de changer de nœud. Il faut donc surveiller les lignes `backup FAILED`.
- **`docker service ls` pour un `replicated-job` :** `MODE replicated job`, `REPLICAS 0/1 (1/1 completed)`. Aucune tâche ne tourne, une tâche est terminée avec succès (`Complete` dans `service ps`), et Swarm ne la relance pas. Avec un service **`replicated` classique**, la `restart_policy` par défaut est `any` : à la fin du `sh -c`, Swarm relancerait la tâche, encore et encore. La restauration se rejouerait en boucle toutes les quelques secondes, et chaque passage effacerait les nouveaux votes. Le service afficherait en plus `0/1` en permanence.

## Étape 5 – Le déménagement réussi

### Procédure (écrite avant de la jouer, puis scriptée dans [scripts/move-db.sh](scripts/move-db.sh))

| # | Action | Commande |
|---|---|---|
| 1 | Geler les écritures : plus d'API, donc plus de votes | `docker service scale quickpoll_api=0` |
| 2 | Sauvegarde à la demande (job ponctuel `pg_dump`) | `sh scripts/backup-now.sh move-<date>` |
| 3 | Basculer les étiquettes | `docker node update --label-rm db manager1` puis `docker node update --label-add db=true worker2` |
| 4 | Attendre une base vide **et saine** sur `worker2` | `docker service ps quickpoll_db --filter desired-state=running` jusqu'à `worker2 … Running` |
| 5 | Restaurer **cette** sauvegarde (pas « la dernière » : la sauvegarde automatique peut en écrire une autre entre-temps) | `sh scripts/restore.sh move-<date>.dump` |
| 6 | Dégeler | `docker service scale quickpoll_api=3` |
| 7 | Vérifier | `curl -s http://quickpoll.localhost:8080/api/poll` → même total qu'avant |

### Exécution chronométrée

`hammer.sh` tournait en parallèle ([captures/05-demenagement-reussi.txt](captures/05-demenagement-reussi.txt), [captures/05-hammer.txt](captures/05-hammer.txt)) :

```text
15:01:27 total avant : 18
15:01:27 | 1. gel des écritures (api -> 0)
15:01:33 | 2. sauvegarde à la demande (move-20261104-150127.dump)
15:01:36 | 3. bascule des étiquettes
15:01:47 |    base Running sur worker2
15:01:51 | 5. restauration OK
15:01:51 | 6. dégel (api -> 3)
real 0m 23.16s
total après : 18                                 quickpoll_db.1 worker2 Running

hammer : 15:01:24 200 total=18 | 15:01:29 502 ... 000 ... 502 | 15:01:56 200 total=18
```

- **0 vote perdu** : 18 avant, 18 après.
- **Votes refusés pendant 27 s** (dernier 200 juste avant 15:01:29, premier 200 à 15:01:56). Le script prend 23 s. Les 4 s de plus correspondent au démarrage des 3 API et à leur passage `healthy`.
- **Comment éviter qu'un vote arrive entre la sauvegarde et la bascule ?** En **arrêtant les écritures avant de prendre la sauvegarde** (étape 1). Sinon, tout vote accepté entre le `pg_dump` et l'arrêt de l'ancienne base serait écrit dans l'ancien volume, puis perdu à la restauration. Ici j'ai mis l'API à 0 réplica, ce qui coupe aussi la lecture des résultats. Une variante plus fine serait un mode « lecture seule » : `ALTER DATABASE quickpoll SET default_transaction_read_only = on`, puis fermer les connexions existantes. Les résultats restent alors lisibles et seuls les votes sont refusés. Le front pourrait aussi afficher une page de maintenance au lieu d'un 502.

## Étape 6 – La panne du nœud de la base

La base tourne sur `worker2`. `hammer.sh` sonde `/api/poll` et une boucle envoie un vote toutes les 0,5 s ([captures/06-panne.txt](captures/06-panne.txt), [captures/06-hammer.txt](captures/06-hammer.txt), [captures/06-votes.txt](captures/06-votes.txt)).

```text
15:02:44 saved /backups/quickpoll-20261104-150244.dump         <- dernière sauvegarde
15:03:19 total juste avant la panne : 107  (dernier vote accepté : id 107 à 15:03:19)
15:03:19 PANNE : docker stop tp5-worker2
15:03:20 503  (hammer) / 503 {"error":"getaddrinfo ENOTFOUND db"} (votes)
```

### Après une minute

```text
worker2   Down   Active
quickpoll_db.1      (aucun nœud)  Running   Pending 47 seconds ago  "no suitable node (scheduling …"
 \_ quickpoll_db.1  worker2       Shutdown  Running 2 minutes ago
docker service ls :  quickpoll_db 1/1   quickpoll_api 4/3   quickpoll_front 3/2   (!)
/api/info  [200] {"db":"down","db_error":"getaddrinfo ENOTFOUND db", ...}
/api/poll  [503] {"error":"getaddrinfo ENOTFOUND db"}
/          [200]
backup : 15:03:43 backup FAILED
```

- **`docker service ps quickpoll_db` :** Swarm a bien créé une tâche de remplacement, mais elle reste **`Pending`** avec `no suitable node (scheduling constraints not satisfied on 3 nodes)`. La seule machine avec `db=true` est `worker2`, qui est `Down`. **La base ne redémarre pas toute seule**, parce que la contrainte la colle à un nœud mort. Et c'est tant mieux : relancée ailleurs, elle démarrerait sur un volume **vide** (étape 2) et l'application continuerait sur une base sans données. Swarm ne sait pas déplacer un volume `local`. Choisir un autre nœud et restaurer une sauvegarde, c'est une décision humaine.
- Piège : `docker service ls` affiche `db 1/1`, `api 4/3`, `front 3/2`. Le manager compte encore comme « running » les tâches de `worker2`, dont il n'a plus de nouvelles (dernier état connu), en plus de leurs remplaçantes. Il faut regarder `docker node ls` et `docker service ps`.
- **Le site n'est pas entièrement en panne.** Le front répond (200) et `/api/info` aussi (200, `"db":"down"`). Les API sur `manager1` et `worker1` tournent, et celles de `worker2` ont été remplacées. Ce qui ne marche plus, c'est tout ce qui touche à la base : `/api/poll` et `/api/vote` répondent 503. La page s'affiche, mais sans résultats, et on ne peut plus voter.

### Reprise sans `worker2`

```bash
docker node update --label-rm db worker2        # possible même si le nœud est Down
docker node update --label-add db=true worker1
until docker service ps quickpoll_db --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' \
      | grep -q '^worker1 Running'; do sleep 1; done
sh scripts/restore.sh                            # dernière sauvegarde : quickpoll-20261104-150244.dump
```

```text
15:04:27 REPRISE : étiquette db sur worker1
15:04:45 base Running (saine) sur worker1        (18 s : pull de postgres:17-alpine + initdb + healthcheck)
15:04:44 200 total=0          <- hammer : base neuve et vide visible pendant 3 s, votes refusés ("relation votes does not exist")
15:04:47 restoring /backups/quickpoll-20261104-150244.dump ... restore OK
15:04:47 200 total=48         <- premier 200 avec les données ; premier vote accepté : id 49
```

### RPO et RTO mesurés

| | Heure (UTC) |
|---|---|
| Dernière sauvegarde réussie | 15:02:44 |
| Dernier vote accepté (id 107) | 15:03:19 |
| Panne (`docker stop`, premier 503) | 15:03:20 |
| Décision et début de la reprise | 15:04:27 |
| Base saine sur `worker1` | 15:04:45 |
| Retour du service (premier 200 avec données, premier vote accepté) | 15:04:47 |

- **RPO mesuré : 36 s de données, soit 59 votes perdus** (ids 49 à 107). Le total est passé de 107 avant la panne à 48 après la restauration.
- **RTO mesuré : 1 min 27 s**, de 15:03:20 à 15:04:47. La partie technique (étiquette, nouvelle base, restauration) ne prend que **20 s**. Les 67 s restantes, c'est l'humain qui constate et décide (ici, la minute d'observation demandée par le sujet). En vrai, c'est surtout le délai d'alerte et d'astreinte qui fixe le RTO.

> À ne pas confondre : après la reprise, la boucle de votes a continué jusqu'à l'id 107 (15:05:22). Le total affiché redevient donc 107 **par coïncidence** : ce sont 59 **nouveaux** votes (ids 49 à 107 réutilisés), pas les anciens.

### Retour de `worker2`

([captures/07-retour-worker2.txt](captures/07-retour-worker2.txt))

```text
worker2   Ready   Active
[worker2] quickpoll_db-data toujours là (46.1M)
[worker2] lecture avec un postgres temporaire : votes=107  max_id=107  dernier_vote=15:03:19.755
quickpoll_db.1 worker2 Shutdown   (Swarm arrête l'ancienne tâche, la base reste sur worker1)
```

- **L'ancien volume est intact.** Il contient les 107 votes jusqu'à 15:03:19, donc **les 59 votes « perdus »**. Swarm ne le supprime pas (il ne gère pas les volumes) et arrête simplement l'ancienne tâche. Leçon : si le nœud peut revenir vite, attendre peut donner un RPO de 0, au prix d'un RTO plus long. On peut aussi récupérer ces votes après coup (dump de l'ancien volume, puis réinjection). Attention cependant : ici les ids 49 à 107 ont été réutilisés par les nouveaux votes.
- **Si l'étiquette `db=true` était encore sur `worker2`** (en plus de `worker1`) : rien ne se passe tout de suite, mais à la prochaine replanification de `db` (`stack deploy`, redémarrage, panne de `worker1`), Swarm pourrait choisir `worker2`. La base y redémarrerait **sur l'ancien volume de 15:03**. Tous les votes reçus depuis la reprise disparaîtraient et les anciens reviendraient, sans aucune erreur visible. Et si `worker2` était le seul nœud étiqueté, la base y repartirait toute seule dès son retour, à côté d'une reprise déjà faite ailleurs.
- **Nettoyage effectué :** étiquette retirée de `worker2` (fait pendant la reprise), anciens conteneurs supprimés, `docker volume rm quickpoll_db-data` sur `worker2` et sur `manager1` (volume périmé depuis l'étape 5). Il ne reste qu'un seul `quickpoll_db-data`, sur `worker1`.

## Étape 7 – Deux bases ?

`replicas: 2` avec `db=true` sur deux nœuds donnerait **deux serveurs Postgres indépendants**, chacun avec son volume local, **sans aucune réplication entre eux** :

- le nouveau serveur démarre sur un volume vide (étape 2) ;
- le nom `db` est une VIP qui répartit les **connexions** entre les deux tâches. Chaque connexion de l'API tombe donc sur l'une ou l'autre base : les votes sont éparpillés, et le total change selon la base qui répond. C'est une incohérence permanente (« split-brain » dès le départ) ;
- `pg_dump -h db` ne sauvegarde qu'**une** des deux bases, au hasard de la connexion, donc les sauvegardes sont incomplètes ;
- si les deux tâches tombaient sur le même nœud (rien ne l'interdit sans `max_replicas_per_node: 1`), elles partageraient le même `PGDATA`. Le verrou `postmaster.pid` empêche la deuxième de démarrer, qui redémarre alors en boucle. Sans ce verrou, ce serait la corruption.

**La bonne solution :** un seul **primaire** qui accepte les écritures, plus un ou plusieurs **réplicas** alimentés par la **réplication en continu** de Postgres (streaming replication, WAL), et un **gestionnaire de bascule** qui promeut un réplica quand le primaire meurt et fait pointer l'application dessus. Par exemple Patroni + etcd/Consul + HAProxy, l'opérateur CloudNativePG sur Kubernetes, ou une base managée (RDS, Cloud SQL, Azure Database…) hors du cluster. Avec une réplication synchrone, le RPO tombe à 0 et le RTO à quelques secondes. Les sauvegardes restent indispensables : la réplication recopie aussi un `DELETE` malheureux.

---

## Runbook – sauvegarder et restaurer la base

À lancer sur le manager, depuis le dossier du TP (`/tp` dans le lab).

**Où vivent les données**

| Donnée | Volume | Nœud | Remarque |
|---|---|---|---|
| Base Postgres | `quickpoll_db-data` (local) | le nœud `db=true` (aujourd'hui `worker1`) | un volume du même nom peut traîner sur un ancien nœud de la base : il est **périmé** |
| Sauvegardes | `quickpoll_backups` (local) | le nœud `backup=true` (`manager1`) | 10 derniers fichiers (`KEEP`), un par minute (`INTERVAL`) |
| Mot de passe | secret `db_password` | Raft des managers | jamais dans Git (`.gitignore`) |
| Images | `registry-data` | `manager1` | |

**État et sauvegardes disponibles**

```bash
docker service ps quickpoll_db quickpoll_backup --filter desired-state=running
docker service logs --tail 5 quickpoll_backup          # une ligne "saved" par minute, pas de "FAILED"
docker exec $(docker ps -qf name=quickpoll_backup) ls -lt /backups
```

**Sauvegarde à la demande**

```bash
sh scripts/backup-now.sh avant-intervention             # -> /backups/avant-intervention.dump
```

**Vérifier une sauvegarde**

```bash
docker exec $(docker ps -qf name=quickpoll_backup) sh -c 'pg_restore --list "$(ls -1t /backups/*.dump | head -1)" | head'
```

**Restaurer**

```bash
curl -s http://quickpoll.localhost:8080/api/poll        # noter le total avant
sh scripts/restore.sh                                   # la plus récente
sh scripts/restore.sh quickpoll-20261104-150244.dump    # ou un fichier précis
curl -s http://quickpoll.localhost:8080/api/poll        # total = celui de la sauvegarde
```

Équivalent sans script :

```bash
docker service create --name restore --mode replicated-job \
  --network quickpoll_back --secret db_password \
  --constraint node.labels.backup==true \
  --mount type=volume,source=quickpoll_backups,target=/backups \
  postgres:17-alpine sh -c 'export PGPASSWORD="$(cat /run/secrets/db_password)";
    f=$(ls -1t /backups/*.dump | head -1); echo "restoring $f";
    pg_restore -h db -U quickpoll -d quickpoll --clean --if-exists "$f"'
docker service logs restore && docker service rm restore
```

**Déménager la base sans perte** (étape 5) : `sh scripts/move-db.sh <nœud actuel> <nouveau nœud>`

**Perte du nœud de la base** (étape 6)

```bash
docker node ls                                          # nœud de la base "Down" ?
docker service ps quickpoll_db                          # tâche "Pending: no suitable node" ?
docker node update --label-rm db <nœud mort>
docker node update --label-add db=true <nœud sain, différent du nœud backup>
until docker service ps quickpoll_db --filter desired-state=running --format '{{.Node}} {{.CurrentState}}' \
      | grep -q '^<nœud sain> Running'; do sleep 1; done
sh scripts/restore.sh
curl -s http://quickpoll.localhost:8080/api/poll
# au retour du nœud mort : vérifier qu'il n'a plus db=true, récupérer si besoin les votes
# de son ancien volume, puis : docker volume rm quickpoll_db-data (sur ce nœud)
```

---

## Vérification finale

([captures/08-etat-final.txt](captures/08-etat-final.txt), [captures/09-rotation.txt](captures/09-rotation.txt))

```text
quickpoll_api      replicated   3/3 (max 2 per node)   127.0.0.1:5000/quickpoll-api:1.0
quickpoll_backup   replicated   1/1                    postgres:17-alpine
quickpoll_db       replicated   1/1                    postgres:17-alpine
quickpoll_front    replicated   2/2                    127.0.0.1:5000/quickpoll-front:1.0   *:8080->80/tcp
manager1 map[backup:true]
worker1 map[db:true]
worker2 map[]
quickpoll_backup.1 manager1 Running        quickpoll_db.1 worker1 Running
```

- Une ligne `saved` par minute, et `/backups` plafonne à 10 fichiers (voir la capture de rotation). Attention : la rotation compte **tous** les `*.dump`, y compris les sauvegardes manuelles (`move-….dump`), qui finissent donc supprimées au bout de 10 minutes. Pour garder une sauvegarde manuelle, il faut la copier ailleurs ou lui donner une autre extension.
- La base (`worker1`) ne tourne pas sur le même nœud que `backup` (`manager1`).
- Une restauration rend le total de la sauvegarde choisie : 15 à l'étape 4, 18 à l'étape 5, 48 à l'étape 6.
- RPO et RTO mesurés à l'étape 6 : **36 s / 59 votes** et **1 min 27 s**.

## Bonus (réponses, non réalisés)

- **Sauvegardes sur NFS :** le service `backup` peut alors tourner sur n'importe quel nœud, et les sauvegardes survivent à la perte de n'importe quel nœud sauf le serveur NFS. **Pas la base sur NFS**, parce que Postgres a besoin de `fsync` fiables et de verrous de fichiers corrects : avec une coupure réseau ou un cache côté client, on risque la corruption. Les performances sont aussi bien moins bonnes, et le serveur NFS devient le nouveau point unique de panne. La HA d'une base passe par la réplication de la base (étape 7), pas par le partage de son disque.
- **Copie hors du cluster :** si `manager1` disparaît aussi, il ne reste **rien** dans ce TP : base et sauvegardes sont perdues. D'où la règle 3-2-1 : 3 copies, 2 supports, 1 hors site (bucket S3 avec `rclone`, chiffré).
- **Planification :** `crazymax/swarm-cronjob` lancerait un `replicated-job` `pg_dump` selon une expression cron, au lieu d'un conteneur qui dort en permanence.
- **Tester la sauvegarde :** un job qui restaure le dernier dump dans une base temporaire et compte les votes. C'est ce que j'ai fait à la main sur l'ancien volume de `worker2`. Une sauvegarde jamais restaurée n'est pas une sauvegarde.
