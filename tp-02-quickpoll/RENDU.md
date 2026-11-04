# TP 2 – QuickPoll : stack multi-services sur Docker Swarm

Date : 07/10/2026

Le but du TP est de faire tourner QuickPoll (front, api, worker, redis, postgres) sur un cluster Swarm de 3 nœuds : corriger le `stack.yml` laissé par l'ancien développeur, le compléter pour la production, faire une mise à jour sans coupure, puis tester ce qui se passe quand on vide des nœuds.

À la fin du TP, les 3 nœuds sont `Ready`, tous les services sont à `n/n`, les 3 réplicas de l'API sont `healthy` et les votes s'enregistrent. Le passage v1 → v2 s'est fait avec `ko=0` et la v3 cassée a été annulée automatiquement.

Fichiers rendus :

| Fichier | Contenu |
|---|---|
| `RENDU.md` | ce compte rendu |
| [stack.yml](stack.yml) | le `stack.yml` corrigé et complété |
| [stack.original.yml](stack.original.yml) | le fichier d'origine, pour comparer |
| [app/api/server.js](app/api/server.js) | bonus : retry avec backoff exponentiel dans `init()` |
| [captures/](captures/) | les sorties de commandes, numérotées dans l'ordre du TP |

---

## 0. Environnement

Comme au TP 1, je n'avais pas 3 machines, j'ai donc utilisé Docker-in-Docker : chaque nœud est un conteneur `docker:dind` qui fait tourner son propre moteur Docker, sur mon PC (Windows 11, Docker Desktop 28.5.1). J'ai créé un cluster neuf, séparé de celui du TP 1.

| Nœud | Rôle | IP (réseau `qp-net`) | Docker Engine | Particularité |
|---|---|---|---|---|
| `qp-manager` | Manager (Leader) | 172.23.0.2 | 29.8.2 | dossier du TP monté dans `/tp`, port 8080 publié sur le PC |
| `qp-worker1` | Worker | 172.23.0.3 | 29.8.2 | label `db=true` |
| `qp-worker2` | Worker | 172.23.0.4 | 29.8.2 | |

```bash
docker network create qp-net
docker run -d --privileged --name qp-manager --hostname qp-manager --network qp-net \
  -p 8080:8080 -v "<chemin du TP>:/tp" docker:dind
docker run -d --privileged --name qp-worker1 --hostname qp-worker1 --network qp-net docker:dind
docker run -d --privileged --name qp-worker2 --hostname qp-worker2 --network qp-net docker:dind
```

- `-v ...:/tp` : le manager voit le code, il peut donc lancer `build-and-push.sh` et `docker stack deploy`.
- `-p 8080:8080` : le port 8080 du PC mène au port 8080 du manager, qui est le port publié par le service `front`. On peut donc ouvrir `http://localhost:8080` dans le navigateur.

Toutes les commandes Swarm sont lancées dans le manager avec `docker exec qp-manager docker ...`. Je les écris sans ce préfixe dans la suite.

---

## Étape 1 – Monter le cluster

```bash
docker swarm init --advertise-addr 172.23.0.2                # sur qp-manager
docker swarm join --token SWMTKN-1-... 172.23.0.2:2377       # sur qp-worker1 et qp-worker2
docker node update --label-add db=true qp-worker1
```

```text
ID                            HOSTNAME     STATUS    AVAILABILITY   MANAGER STATUS   ENGINE VERSION
bwmi8j3r8kzohzen0li7z5ukp *   qp-manager   Ready     Active         Leader           29.8.2
npnc0d3dky00i5lk0vfaj4f1u     qp-worker1   Ready     Active                          29.8.2
kakdc9lds0ygwq02c841da2tb     qp-worker2   Ready     Active                          29.8.2
map[db:true]
```
(voir [captures/01-swarm-init.txt](captures/01-swarm-init.txt), [captures/02-node-ls.txt](captures/02-node-ls.txt))

### 1.5 Registry privé + images

J'ai utilisé le registry privé dans le cluster, comme demandé, sans passer par Docker Hub.

```bash
docker service create --name registry --publish 5000:5000 registry:2
apk add curl            # le script utilise curl à la fin, absent de l'image docker:dind
cd /tp && sh scripts/build-and-push.sh
```

```text
>> 127.0.0.1:5000/quickpoll-front:v1
>> 127.0.0.1:5000/quickpoll-worker:v1
>> 127.0.0.1:5000/quickpoll-api:v1
>> 127.0.0.1:5000/quickpoll-api:v2
>> 127.0.0.1:5000/quickpoll-api:v3
Images disponibles :
{"repositories":["quickpoll-api","quickpoll-front","quickpoll-worker"]}
```

J'ai vérifié que les workers, qui ne font pas tourner le registry, y accèdent aussi :

```text
== qp-worker1
{"repositories":["quickpoll-api","quickpoll-front","quickpoll-worker"]}
{"name":"quickpoll-api","tags":["v2","v3","v1"]}
== qp-worker2
{"repositories":["quickpoll-api","quickpoll-front","quickpoll-worker"]}
{"name":"quickpoll-api","tags":["v2","v3","v1"]}
```
(voir [captures/03-registry.txt](captures/03-registry.txt), [captures/04-build-and-push.txt](captures/04-build-and-push.txt))

### Question 1.1 – Pourquoi `127.0.0.1:5000` est-il joignable depuis tous les nœuds ?

C'est le routing mesh de Swarm. Un service publié avec `--publish 5000:5000` est publié en mode `ingress` : chaque nœud du cluster écoute sur le port 5000, même s'il n'a pas de tâche `registry`. Quand un nœud reçoit une connexion sur ce port, il la fait suivre par le réseau overlay `ingress` (IPVS) vers une tâche du service, quel que soit le nœud où elle tourne.

Sur n'importe quel nœud, `127.0.0.1:5000` arrive donc au registry. Ça a deux avantages :
1. Le même nom d'image `127.0.0.1:5000/quickpoll-api:v1` marche sur tous les nœuds.
2. Docker considère `127.0.0.0/8` comme un registry de confiance : pas besoin de TLS ni de configurer `insecure-registries` sur chaque moteur.

---

## Étape 2 – Déboguer le `stack.yml`

Premier déploiement du fichier d'origine :

```text
$ docker stack deploy -c stack.yml quickpoll
Ignoring unsupported options: build
...
NAME                 REPLICAS   IMAGE
quickpoll_api        0/1        quickpoll-api:v1
quickpoll_front      0/1        quickpoll-front:v1
quickpoll_postgres   1/1        postgres:16-alpine     *:5432->5432/tcp
quickpoll_redis      1/1        redis:7-alpine
quickpoll_worker     0/1        quickpoll-worker:v1

quickpoll_api.1     qp-worker2   Rejected 44 seconds ago   "pull access denied for quickpoll-api, repository does not exist ..."
quickpoll_front.1   qp-worker2   Rejected 4 seconds ago    "pull access denied for quickpoll-front, repository does not exist ..."
```
(voir [captures/05-deploy-original.txt](captures/05-deploy-original.txt))

Pour voir les problèmes un par un, j'ai d'abord seulement préfixé les trois `image:` par `127.0.0.1:5000/`, sans rien toucher d'autre, puis j'ai redéployé ([captures/06-deploy-images-fixed.txt](captures/06-deploy-images-fixed.txt)). Les risques qui ne se voient pas au déploiement sont montrés dans [captures/07-risques-invisibles.txt](captures/07-risques-invisibles.txt).

Les numéros de ligne correspondent à [stack.original.yml](stack.original.yml).

### Problème 1 – Images sans registry (lignes 7, 17, 36)

```yaml
image: quickpoll-front:v1     # idem quickpoll-api:v1 et quickpoll-worker:v1
build: ./app/front
```

- **Symptôme** : `front`, `api` et `worker` restent à `0/1` avec l'erreur `pull access denied for quickpoll-api, repository does not exist`. `docker stack deploy` ignore `build:` (*Ignoring unsupported options: build*). Sans préfixe, Docker cherche `docker.io/library/quickpoll-api`, qui n'existe pas. Et même si l'image avait été construite sur le manager, les workers ne l'auraient pas eue.
- **Correction** : `image: ${REGISTRY:-127.0.0.1:5000}/quickpoll-api:${API_TAG:-v1}` (pareil pour front et worker), et suppression de `build:`.
- **Justification** : en Swarm, chaque nœud télécharge lui-même l'image, elle doit donc venir d'un registry que tous les nœuds peuvent joindre. Le build se fait avant, en CI ou avec `build-and-push.sh`.

### Problème 2 – `restart_policy: condition: none` sur l'API (ligne 32)

```yaml
restart_policy:
  condition: none
```

- **Symptôme** : une fois les images corrigées, l'API démarre avant que Postgres soit prêt. Son `init()` échoue et le process s'arrête. Swarm ne la relance pas : le service reste à `0/1` et le site renvoie des 502.
  ```text
  quickpoll_api   replicated   0/1   127.0.0.1:5000/quickpoll-api:v1
  quickpoll_api.1   qp-manager   Shutdown   Failed 39 seconds ago   "task: non-zero exit (1)"
  init failed: getaddrinfo ENOTFOUND postgres
  ```
- **Correction** : `condition: any` (avec `delay: 5s`, `window: 30s`) et 3 réplicas.
- **Justification** : `depends_on` est ignoré par Swarm, il n'y a aucun ordre de démarrage garanti. C'est la politique de redémarrage qui doit compenser. Un service sans état comme l'API doit toujours être relancé.

### Problème 3 – Mot de passe en clair (lignes 22, 41, 59)

```yaml
DB_PASSWORD: SuperSecret2026!
POSTGRES_PASSWORD: SuperSecret2026!
```

- **Risque (sécurité)** : le mot de passe est dans le dépôt Git, donc dans tout l'historique. Il est aussi visible par toute personne qui a accès à l'API Docker :
  ```text
  $ docker service inspect quickpoll_postgres --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}'
  ["POSTGRES_DB=quickpoll","POSTGRES_PASSWORD=SuperSecret2026!","POSTGRES_USER=quickpoll"]
  ```
  On le retrouve aussi dans `docker inspect` du conteneur et dans `/proc/<pid>/environ`.
- **Correction** : un `docker secret` externe, `quickpoll_db_password`, monté dans `/run/secrets/db_password`. L'API et le worker lisent `DB_PASSWORD_FILE`, Postgres lit `POSTGRES_PASSWORD_FILE`. Le secret est créé hors du dépôt :
  ```bash
  head -c 24 /dev/urandom | base64 | docker secret create quickpoll_db_password -
  ```
- **Justification** : un secret Swarm est chiffré dans le Raft des managers, il n'est envoyé qu'aux nœuds qui font tourner une tâche qui y a droit, et il est monté en `tmpfs` (jamais écrit sur le disque du worker). Après correction, la spec ne contient plus que le chemin :
  ```text
  ["POSTGRES_DB=quickpoll","POSTGRES_PASSWORD_FILE=/run/secrets/db_password","POSTGRES_USER=quickpoll"]
  ```

### Problème 4 – Postgres publié sur le port 5432 (ligne 61)

```yaml
ports:
  - "5432:5432"
```

- **Risque (sécurité)** : à cause du routing mesh (voir Q1.1), la base est ouverte sur le port 5432 de tous les nœuds, donc depuis l'extérieur du cluster, avec un mot de passe qui est en plus dans le dépôt :
  ```text
  qp-worker1:5432 -> OUVERT
  qp-worker2:5432 -> OUVERT
  ```
- **Correction** : suppression de `ports:`. Postgres n'est joignable que par le réseau overlay `backend`.
- **Justification** : seuls l'API et le worker ont besoin de la base, et ils y accèdent par le DNS interne (`postgres:5432`). Après correction : `5432 fermé`.

### Problème 5 – Volume Postgres sans placement (ligne 63 + absence de `placement`)

```yaml
volumes:
  - pgdata:/var/lib/postgresql/data
# ... et aucune contrainte de placement
```

- **Risque (perte de données)** : `pgdata` est un volume local, il n'existe que sur le nœud où il a été créé. Sans contrainte, Swarm peut placer Postgres sur n'importe quel nœud. Si le nœud tombe, est vidé, ou au déploiement suivant, Postgres peut repartir ailleurs avec un volume neuf et vide. Je l'ai vu entre mes deux premiers déploiements : Postgres tournait sur `qp-manager` au premier ([captures/05](captures/05-deploy-original.txt)) et sur `qp-worker2` au second, où un nouveau `quickpoll_pgdata` a été créé :
  ```text
  qp-manager:
  qp-worker1:
  qp-worker2: quickpoll_pgdata
  quickpoll_postgres.1 -> qp-worker2
  ```
- **Correction** : `placement.constraints: [node.labels.db == true]`. Postgres tourne toujours sur `qp-worker1`, donc toujours avec le même volume.
- **Justification** : c'est à ça que sert le label posé à l'étape 1 : le service à état reste sur le nœud qui porte ses données.

> Un autre défaut est traité à l'étape 3 : il n'y a qu'un seul réseau `quickpoll` pour tout le monde, donc le `front`, exposé à Internet, peut joindre directement `redis` et `postgres`.

Point de contrôle : `http://localhost:8080` affiche la page et les votes s'enregistrent (voir les vérifications de l'étape 3).

---

## Étape 3 – Stack production-ready

Le fichier complet : [stack.yml](stack.yml) (rendu final vérifié avec `docker stack config`, [captures/09-stack-config.txt](captures/09-stack-config.txt)).

| # | Exigence | Réalisation |
|---|---|---|
| 1 | Aucun secret en clair | secret externe `quickpoll_db_password` (voir problème 3) |
| 2 | Postgres épinglé + accès restreint | contrainte `node.labels.db == true`, aucun port publié, uniquement sur `backend` (problèmes 4 et 5) |
| 3 | Deux réseaux overlay | `frontend` (front + api) et `backend` (api + worker + redis + postgres). `backend` est en plus `internal: true` : ses conteneurs n'ont pas de sortie vers l'extérieur |
| 4 | API : 3 réplicas, healthcheck, restart | `replicas: 3`, healthcheck en `node -e "fetch(...)"` (Node 22 a `fetch` intégré, pas besoin de curl), `restart_policy: condition: any, delay: 5s` |
| 5 | Tags paramétrables | `${API_TAG:-v1}`, et aussi `${FRONT_TAG:-v1}`, `${WORKER_TAG:-v1}`, `${REGISTRY:-127.0.0.1:5000}` |

Le healthcheck est réglé avec `interval: 5s, timeout: 3s, retries: 3, start_period: 10s` : une tâche cassée est marquée `unhealthy` en 25 s environ. Je m'en sers pour régler le `monitor` à l'étape 4.

### Déploiement

```text
$ docker stack deploy -c stack.yml quickpoll
Creating network quickpoll_frontend
Creating network quickpoll_backend
...
NAME                 REPLICAS   IMAGE
quickpoll_api        3/3        127.0.0.1:5000/quickpoll-api:v1
quickpoll_front      2/2        127.0.0.1:5000/quickpoll-front:v1    *:8080->80/tcp
quickpoll_postgres   1/1        postgres:16-alpine
quickpoll_redis      1/1        redis:7-alpine
quickpoll_worker     1/1        127.0.0.1:5000/quickpoll-worker:v1

quickpoll_postgres.1     qp-worker1   Running      <- nœud db=true
quickpoll_worker.1       qp-manager   Running
 \_ quickpoll_worker.1   qp-manager   Failed       "task: non-zero exit (1)"  <- Postgres pas prêt, relancé par Swarm
```
(voir [captures/10-deploy-final.txt](captures/10-deploy-final.txt))

### Vérifications ([captures/11-verification.txt](captures/11-verification.txt), [captures/11b-isolation.txt](captures/11b-isolation.txt))

```text
== Votes :
{"queued":"c8473870-85ed-4835-a41b-5078893a1a05"}   (x5)
== Résultats :
{"version":"v1","results":[{"option":"kubernetes","count":1},{"option":"nomad","count":1},{"option":"swarm","count":3}]}

== Santé des tâches API :
qp-manager quickpoll_api.3   Up About a minute (healthy)
qp-worker1 quickpoll_api.1   Up About a minute (healthy)
qp-worker2 quickpoll_api.2   Up About a minute (healthy)

== Depuis un conteneur front (réseau frontend uniquement) :
api:3000       joignable
postgres:5432  nom inconnu -> ISOLÉ
redis:6379     nom inconnu -> ISOLÉ
== Depuis un conteneur api (frontend + backend) :
postgres:5432  joignable
redis:6379     joignable
```

J'ai d'abord testé l'isolation avec `nslookup`, mais la commande renvoie 0 même quand le nom n'existe pas, ce qui donnait un faux positif. J'ai refait le test avec `getent hosts` et une vraie connexion TCP.

### Question 3.1 – `depends_on` est ignoré : comment garantir que l'API fonctionne si Postgres démarre après elle ?

Côté Swarm, on n'impose pas d'ordre de démarrage, on fait en sorte que l'ordre n'ait pas d'importance :
- `restart_policy: condition: any` + `delay` : si un service s'arrête faute de base, Swarm le relance jusqu'à ce que ça marche. On le voit au déploiement ci-dessus avec la tâche `worker` en `Failed` puis relancée.
- `healthcheck` : tant qu'une tâche ne répond pas correctement à `/api/health` (qui fait un `SELECT 1`), Swarm ne la considère pas comme prête et le rolling update n'avance pas. Si elle devient `unhealthy` plus tard, elle est remplacée.

La vraie réponse est architecturale : c'est l'application qui doit supporter l'absence de ses dépendances, pas l'orchestrateur qui doit fixer un ordre. Postgres peut aussi redémarrer ou changer de nœud pendant que l'API tourne, pas seulement au démarrage, donc un ordre de démarrage ne réglerait qu'une partie du problème. L'application doit :
- réessayer sa connexion avec un backoff exponentiel (avec un peu d'aléatoire) au lieu de s'arrêter tout de suite ;
- supporter une coupure de la base en cours de route (le pool `pg` se reconnecte) ;
- idéalement, distinguer liveness (le process est vivant) et readiness (les dépendances répondent).

Le passage par Redis va dans ce sens : un vote est accepté (`202`) même si Postgres est indisponible, le worker l'écrira plus tard.

### Bonus – Retry avec backoff exponentiel ([app/api/server.js](app/api/server.js))

`init()` réessaie le `CREATE TABLE` jusqu'à 8 fois, avec des délais de 0,5 s, 1 s, 2 s, 4 s, 8 s puis 15 s (plafond). Après le 8e échec, le process s'arrête et la `restart_policy` de Swarm prend le relais. `redis.connect()` n'est appelé qu'après le succès, pour ne pas ouvrir la connexion deux fois. Les images ont été reconstruites et repoussées après la modification ([captures/08-rebuild-bonus.txt](captures/08-rebuild-bonus.txt)). Logs au premier déploiement :

```text
postgres indisponible (getaddrinfo ENOTFOUND postgres), essai 1/8, retry dans 500 ms
postgres indisponible (getaddrinfo ENOTFOUND postgres), essai 2/8, retry dans 1000 ms
postgres indisponible (getaddrinfo ENOTFOUND postgres), essai 3/8, retry dans 2000 ms
postgres indisponible (getaddrinfo ENOTFOUND postgres), essai 4/8, retry dans 4000 ms
postgres indisponible (connect ECONNREFUSED 10.0.2.2:5432), essai 5/8, retry dans 8000 ms
api v1 listening on 3000
```

Le DNS `postgres` finit par répondre (`ENOTFOUND` devient `ECONNREFUSED`), puis Postgres accepte les connexions et l'API démarre sans avoir été relancée par Swarm.

Je n'ai pas ajouté d'aléatoire (jitter) dans le délai : avec 3 réplicas ce n'est pas gênant, mais avec beaucoup d'instances elles réessaieraient toutes en même temps.

---

## Étape 4 – Rolling update sans coupure

Configuration de l'API :

```yaml
update_config:
  parallelism: 1            # un réplica à la fois
  delay: 5s
  order: start-first        # le nouveau conteneur démarre avant l'arrêt de l'ancien
  failure_action: rollback  # un échec déclenche un rollback automatique
  monitor: 30s              # > start_period + interval * retries (25 s)
  max_failure_ratio: 0      # aucune tâche en échec tolérée
rollback_config:
  parallelism: 1
  delay: 5s
  order: start-first
  failure_action: pause
  monitor: 30s
```

### v1 → v2

```bash
./scripts/curl-loop.sh http://localhost:8080          # dans un 2e terminal
API_TAG=v2 docker stack deploy -c stack.yml quickpoll
```

Capture de la sonde pendant le passage v1 → v2 (extraits de [captures/12-sonde-v1-v2.txt](captures/12-sonde-v1-v2.txt), sortie du déploiement dans [captures/12b-deploy-v2.txt](captures/12b-deploy-v2.txt)) :

```text
09:10:23  {"version":"v1","host":"d3796e96c1d8"} 200  (ok=1 ko=0)
09:10:23  {"version":"v1","host":"5e40dbe3605b"} 200  (ok=2 ko=0)
09:10:24  {"version":"v1","host":"efad570e40f4"} 200  (ok=3 ko=0)
...
09:10:36  {"version":"v1","host":"d3796e96c1d8"} 200  (ok=46 ko=0)
09:10:37  {"version":"v2","host":"e24334384638"} 200  (ok=47 ko=0)   <- 1er réplica v2
09:10:37  {"version":"v1","host":"efad570e40f4"} 200  (ok=48 ko=0)
09:10:37  {"version":"v1","host":"d3796e96c1d8"} 200  (ok=49 ko=0)
09:10:38  {"version":"v2","host":"e24334384638"} 200  (ok=50 ko=0)
...
09:10:58  {"version":"v2","host":"cb81cf33750f"} 200  (ok=119 ko=0)
09:10:59  {"version":"v1","host":"efad570e40f4"} 200  (ok=120 ko=0)   <- dernière réponse v1
09:10:59  {"version":"v2","host":"ce42e20255f6"} 200  (ok=121 ko=0)
...
09:11:37  {"version":"v2","host":"e24334384638"} 200  (ok=249 ko=0)
09:11:37  {"version":"v2","host":"ce42e20255f6"} 200  (ok=250 ko=0)
```

250 requêtes, `ko=0`. Pendant une vingtaine de secondes, v1 et v2 répondent en même temps, puis il ne reste que les 3 conteneurs v2.

### v3 cassée → rollback automatique

```bash
API_TAG=v3 docker stack deploy -c stack.yml quickpoll
```

```text
09:11:49 updating
09:12:05 updating
09:12:10 rollback_started          <- la tâche v3 est unhealthy, l'update échoue
09:12:42 rollback_started
09:12:48 rollback_completed

$ docker service inspect quickpoll_api --format '{{.UpdateStatus.State}}'
rollback_completed
Image courante : 127.0.0.1:5000/quickpoll-api:v2@sha256:3432...

 \_ quickpoll_api.2   127.0.0.1:5000/quickpoll-api:v3   qp-worker2   Shutdown   Complete 41 seconds ago
```
(voir [captures/13b-update-status.txt](captures/13b-update-status.txt), [captures/13c-rollback.txt](captures/13c-rollback.txt))

Swarm est revenu seul en v2. Avec `start-first`, la seule tâche v3 lancée n'a jamais remplacé une tâche v2 saine : la sonde n'a reçu aucune réponse v3 et termine à `ko=0` sur 214 requêtes ([captures/13-sonde-v3.txt](captures/13-sonde-v3.txt)).

### Question 4.1 – Que se passerait-il avec `order: stop-first` et `replicas: 1` ?

Swarm arrête d'abord l'unique conteneur v1, puis démarre le v2. Entre les deux, plus personne ne sert l'API : le temps d'arrêter l'ancien, de télécharger l'image si besoin, de démarrer Node, de faire `init()` et de passer le healthcheck. Pendant ce temps nginx renvoie des 502 et la sonde compte des `ko`. Si la nouvelle version est cassée, la coupure dure jusqu'à la fin du rollback.

Pour mettre à jour un service sans état sans coupure, il faut donc au moins 2 réplicas ou `start-first`, et de préférence les deux comme ici. `stop-first` reste utile quand deux instances ne peuvent pas tourner en même temps, par exemple une base de données sur un volume exclusif.

---

## Étape 5 – Chaos

### Drain du nœud le plus chargé (sans Postgres)

10 votes de plus (15 au total), puis répartition des tâches ([captures/14-avant-drain.txt](captures/14-avant-drain.txt)) :

```text
{"results":[{"option":"kubernetes","count":5},{"option":"nomad","count":4},{"option":"swarm","count":6}]}
qp-manager quickpoll_api.1, quickpoll_api.2, quickpoll_worker.1   (+ le registry)
qp-worker1 quickpoll_api.3, quickpoll_front.1, quickpoll_postgres.1
qp-worker2 quickpoll_front.2, quickpoll_redis.1
```

`qp-manager` est celui qui porte le plus de tâches sans porter Postgres :

```text
$ docker node update --availability drain qp-manager
qp-manager   Ready   Drain   Leader

quickpoll_api.1          qp-worker2   Running 34 seconds ago
 \_ quickpoll_api.1      qp-manager   Shutdown 41 seconds ago
quickpoll_api.2          qp-worker1   Running 34 seconds ago
 \_ quickpoll_api.2      qp-manager   Shutdown 41 seconds ago
quickpoll_worker.1       qp-worker2   Running 39 seconds ago
 \_ quickpoll_worker.1   qp-manager   Shutdown 40 seconds ago
registry.1               qp-worker2   Running 41 seconds ago

== Résultats après drain :
{"results":[{"option":"kubernetes","count":5},{"option":"nomad","count":4},{"option":"swarm","count":6}]}
```
(voir [captures/15b-apres-drain.txt](captures/15b-apres-drain.txt))

Les tâches sont redistribuées sur les deux workers, les 15 votes sont toujours là, et la sonde, qui tournait pendant le drain, termine à `ko=0` sur 151 requêtes ([captures/15-sonde-drain.txt](captures/15-sonde-drain.txt)). Le port 8080 du manager continue de répondre alors qu'il n'a plus aucune tâche : c'est encore le routing mesh.

### Remise en `active` : les tâches reviennent-elles ?

```text
$ docker node update --availability active qp-manager
== 30 s après réactivation, tâches sur qp-manager :
(aucune)
```
(voir [captures/16-reactivation.txt](captures/16-reactivation.txt))

Non. Swarm ne rééquilibre pas tout seul : il cherche seulement à respecter l'état désiré (3 réplicas d'API, etc.), et cet état est déjà respecté, donc il ne déplace rien. Déplacer des tâches qui marchent provoquerait des redémarrages inutiles. Le nœud ne resservira que pour de nouvelles tâches : nouveau déploiement, mise à jour, panne ailleurs, ou `docker service update --force <svc>` pour forcer une redistribution.

J'ai essayé ce `--force` sur l'API, mais il a échoué à cause du problème du registry décrit juste après : les tâches sont restées sur les workers. C'est le redéploiement final qui a remis des tâches sur `qp-manager` (voir l'état final).

### Imprévu : le registry a perdu ses images

En vidant `qp-manager`, j'ai aussi déplacé le registry sur `qp-worker2`. Le service `registry:2` avait été créé sans volume, comme dans l'énoncé, il a donc redémarré vide :

```text
== Catalogue du registry après sa migration sur qp-worker2 :
{"repositories":[]}
```

Le worker a pu redémarrer uniquement parce que l'image était déjà en cache sur `qp-worker2`. Par contre, le `docker service update --force quickpoll_api` a échoué avec `failed to resolve reference` : le service est épinglé sur le digest de la v2 d'origine, qui n'existait plus nulle part. Le rollback automatique a gardé l'ancienne version en place ([captures/15c-registry-apres-drain.txt](captures/15c-registry-apres-drain.txt)).

Correction : registry épinglé sur le manager avec un volume persistant, puis nouveau push des images et redéploiement de la v2 ([captures/17-registry-persistant.txt](captures/17-registry-persistant.txt)) :

```bash
docker service update --constraint-add node.role==manager \
  --mount-add type=volume,source=registry-data,target=/var/lib/registry registry
sh scripts/build-and-push.sh
API_TAG=v2 docker stack deploy -c stack.yml quickpoll
```

C'est le même défaut que le problème 5 (un service à état sans volume ni placement), mais sur le registry. En production on utiliserait plutôt un registry externe avec un stockage objet (Docker Hub, GHCR, Harbor…).

### Question 5.1 – Le worker est-il idempotent si un vote est rejoué ?

Oui pour l'écriture en base, grâce à deux éléments du code :
- l'API génère `vote_id = crypto.randomUUID()` avant de mettre le vote dans Redis, donc un vote rejoué garde le même id ;
- la table a `vote_id TEXT UNIQUE NOT NULL`, et le worker insère avec
  ```sql
  INSERT INTO votes (vote_id, option) VALUES ($1, $2) ON CONFLICT (vote_id) DO NOTHING
  ```
  Un vote rejoué tombe sur la contrainte d'unicité et n'est pas compté deux fois.

En revanche la livraison n'est pas garantie : `BRPOP` retire le vote de Redis avant l'`INSERT`. Si le conteneur est tué entre les deux (délai d'arrêt dépassé, crash, OOM), le vote est perdu, pas rejoué. Le `SIGTERM` est géré (`running = false`, la boucle en cours se termine), donc un drain normal ne perd rien. Pour avoir une livraison « au moins une fois », il faudrait faire `BLMOVE votes → votes:processing`, puis `LREM` après l'`INSERT` ; l'idempotence ci-dessus rendrait alors les rejeux sans danger. Autre point : Redis n'a ni volume ni AOF, donc une file non vidée est perdue si Redis change de nœud.

### Question 5.2 – Que se passe-t-il si on vide le nœud `db=true` ?

Je l'ai testé ([captures/18-drain-db.txt](captures/18-drain-db.txt)) :

```text
$ docker node update --availability drain qp-worker1
quickpoll_postgres.1               Running   Pending 25 seconds ago
  "no suitable node (scheduling constraints not satisfied on 2 nodes; 1 node not available for new tasks)"

== /api/results pendant que postgres est Pending :
502 Bad Gateway

$ docker node update --availability active qp-worker1
quickpoll_postgres.1   qp-worker1   Running
{"results":[{"option":"kubernetes","count":5},{"option":"nomad","count":4},{"option":"swarm","count":6}]}
```

Postgres est arrêté et ne peut aller nulle part, puisqu'aucun autre nœud n'a le label `db=true` : la tâche reste `Pending`. Les healthchecks de l'API (`SELECT 1`) échouent, Swarm relance les tâches API et le site renvoie des 502. Les votes reçus pendant ce temps restent dans Redis. Quand le nœud revient, Postgres redémarre sur le même volume et les données sont intactes.

Si j'avais mis le label sur un deuxième nœud, Postgres aurait redémarré là-bas avec un volume vide : c'est le problème 5.

Ce que ça montre sur les limites de Swarm pour les services à état :
- Swarm ne gère pas le stockage. Un volume `local` est lié à un nœud, sans réplication ni rattachement automatique ailleurs. Il n'y a pas d'équivalent aux PersistentVolumes / StorageClasses de Kubernetes (CSI), qui permettent de rattacher un disque réseau sur un autre nœud.
- Épingler le service sur un nœud protège les données mais en fait un point unique de défaillance : on garde les données, on perd la disponibilité.
- Pas d'identité stable ni d'ordre de démarrage (pas d'équivalent aux StatefulSets), et Swarm ne sait rien de la réplication primaire/secondaire de Postgres.

En pratique, on sort la base du cluster (base managée type RDS ou Cloud SQL), ou on utilise un volume réseau avec un driver (NFS, Portworx…), ou on laisse la base gérer sa réplication (Patroni). Swarm sert alors surtout pour les services sans état.

---

## État final de la stack

([captures/19-etat-final.txt](captures/19-etat-final.txt))

```text
ID            HOSTNAME     STATUS  AVAILABILITY  MANAGER STATUS
bwmi8j3r...*  qp-manager   Ready   Active        Leader
npnc0d3d...   qp-worker1   Ready   Active
kakdc9ld...   qp-worker2   Ready   Active

NAME                 MODE         REPLICAS   IMAGE                                PORTS
quickpoll_api        replicated   3/3        127.0.0.1:5000/quickpoll-api:v2
quickpoll_front      replicated   2/2        127.0.0.1:5000/quickpoll-front:v1    *:8080->80/tcp
quickpoll_postgres   replicated   1/1        postgres:16-alpine
quickpoll_redis      replicated   1/1        redis:7-alpine
quickpoll_worker     replicated   1/1        127.0.0.1:5000/quickpoll-worker:v1

quickpoll_api.1        quickpoll-api:v2      qp-worker2   Running
quickpoll_api.2        quickpoll-api:v2      qp-worker1   Running
quickpoll_api.3        quickpoll-api:v2      qp-manager   Running
quickpoll_front.1      quickpoll-front:v1    qp-worker2   Running
quickpoll_front.2      quickpoll-front:v1    qp-manager   Running
quickpoll_postgres.1   postgres:16-alpine    qp-worker1   Running   <- nœud db=true
quickpoll_redis.1      redis:7-alpine        qp-worker2   Running
quickpoll_worker.1     quickpoll-worker:v1   qp-manager   Running

qp-manager quickpoll_api.3   Up 53 seconds (healthy)
qp-worker1 quickpoll_api.2   Up About a minute (healthy)
qp-worker2 quickpoll_api.1   Up About a minute (healthy)

$ curl http://localhost:8080/api/version
{"version":"v2","host":"6d410379084b"}
$ curl http://localhost:8080/api/results
{"version":"v2","results":[{"option":"kubernetes","count":5},{"option":"nomad","count":4},{"option":"swarm","count":6}]}
```

Tous les services sont à `n/n`, les 3 API sont `healthy`, et les 15 votes sont toujours là après les deux drains, l'arrêt de Postgres et le redéploiement de la v2.

---

## Pour aller plus loin (discussion)

**Swarm face à Kubernetes.** Pour un petit cluster, une équipe réduite et des services surtout sans état, Swarm suffit : on reste sur le format Compose, et le TLS entre nœuds et les secrets sont fournis sans rien installer. Ce TP montre où ça coince. Dès qu'il faut du stockage à état sérieux (CSI, StatefulSets), de l'autoscaling, des sondes readiness et liveness séparées, un ingress L7, des network policies plus fines que « qui partage quel réseau », ou du RBAC et du multi-tenant (namespaces, quotas), il faut passer à Kubernetes. Son écosystème (Helm, opérateurs, GitOps avec ArgoCD ou Flux) pèse aussi dans le choix.

**dev / staging / prod.** Un `stack.yml` de base commun, puis un fichier d'override par environnement, fusionnés au déploiement :
```bash
docker stack deploy -c stack.yml -c stack.prod.yml quickpoll
```
- `stack.yml` : services, réseaux, healthchecks ;
- `stack.dev.yml` : 1 réplica, Postgres publié en local pour déboguer, pas de contrainte de placement ;
- `stack.prod.yml` : nombre de réplicas, `update_config`, placement, limites de ressources, secrets externes.

Les variables (`API_TAG`, `REGISTRY`) sont fournies par la CI. On déploie une stack par environnement (`quickpoll-staging`, `quickpoll-prod`), ce qui sépare les réseaux et les noms de services, et idéalement la prod sur son propre cluster.
