# TP 2 – QuickPoll : stack multi-services sur Docker Swarm

Date : 07/10/2026

Le but du TP est de faire tourner QuickPoll (front, api, worker, redis, postgres) en production sur un cluster Swarm de 3 nœuds : corriger le `stack.yml` laissé par l'ancien développeur, le rendre « production-ready », faire des mises à jour sans coupure, puis tester la résistance du cluster.

**Résultat : la stack tourne correctement** : 3 nœuds `Ready`, tous les services à `n/n`, les 3 réplicas de l'API `healthy`, les votes s'enregistrent, la mise à jour v1 → v2 se fait avec `ko=0` et la v3 cassée est annulée automatiquement.

Fichiers rendus :

| Fichier | Contenu |
|---|---|
| `RENDU.md` | ce compte rendu |
| [stack.yml](stack.yml) | le `stack.yml` corrigé et complété |
| [stack.original.yml](stack.original.yml) | le fichier d'origine (pour comparer) |
| [app/api/server.js](app/api/server.js) | bonus : retry avec backoff exponentiel dans `init()` |
| [captures/](captures/) | toutes les sorties de commandes, numérotées dans l'ordre du TP |

---

## 0. Environnement

Comme au TP 1, je n'avais pas 3 machines : j'ai utilisé **Docker-in-Docker**. Chaque nœud est un conteneur `docker:dind` qui fait tourner son propre moteur Docker, sur mon PC (Windows 11, Docker Desktop 28.5.1). J'ai créé un cluster neuf, séparé de celui du TP 1.

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

Toutes les commandes Swarm sont lancées dans le manager avec `docker exec qp-manager docker ...`. Pour plus de lisibilité, je les écris sans ce préfixe dans la suite.

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

J'ai suivi la méthode demandée (registry privé dans le cluster). **Elle a fonctionné, je n'ai pas eu besoin de Docker Hub.**

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

J'ai vérifié que les **workers**, qui ne font pas tourner le registry, y accèdent aussi :

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

Grâce au **routing mesh** de Swarm. Un service publié avec `--publish 5000:5000` est publié en mode `ingress` : **chaque nœud** du cluster écoute sur le port 5000, même ceux qui n'ont pas de tâche `registry`. Quand un nœud reçoit une connexion sur ce port, il la fait suivre par le réseau overlay `ingress` (avec IPVS) vers une tâche du service, quel que soit le nœud où elle tourne.

Donc sur n'importe quel nœud, `127.0.0.1:5000` arrive au registry. C'est pratique pour deux raisons :
1. Le même nom d'image `127.0.0.1:5000/quickpoll-api:v1` marche sur tous les nœuds.
2. Docker considère `127.0.0.0/8` comme un registry « de confiance » : pas besoin de TLS ni de configurer `insecure-registries` sur chaque moteur.

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

Pour voir les problèmes l'un après l'autre, j'ai d'abord corrigé uniquement les images ([captures/stack.step-images-only.yml](captures/stack.step-images-only.yml)) puis j'ai redéployé ([captures/06-deploy-images-fixed.txt](captures/06-deploy-images-fixed.txt)). Les risques qu'on ne voit pas au déploiement sont montrés dans [captures/07-risques-invisibles.txt](captures/07-risques-invisibles.txt).

Les numéros de ligne correspondent à [stack.original.yml](stack.original.yml).

### Problème 1 – Images sans registry (lignes 7, 17, 36)

```yaml
image: quickpoll-front:v1     # idem quickpoll-api:v1 et quickpoll-worker:v1
build: ./app/front
```

- **Symptôme** : `front`, `api` et `worker` restent à `0/1` avec l'erreur `pull access denied for quickpoll-api, repository does not exist`. `docker stack deploy` ignore `build:` (*Ignoring unsupported options: build*). Sans préfixe, Docker cherche l'image `docker.io/library/quickpoll-api`, qui n'existe pas. Même si l'image avait été construite sur le manager, les workers ne l'auraient pas.
- **Correction** : `image: ${REGISTRY:-127.0.0.1:5000}/quickpoll-api:${API_TAG:-v1}` (même chose pour front et worker), et suppression de `build:`.
- **Justification** : en Swarm, chaque nœud télécharge lui-même l'image. Elle doit donc venir d'un registry joignable par tous les nœuds. Le build se fait avant, en CI ou avec `build-and-push.sh`.

### Problème 2 – `restart_policy: condition: none` sur l'API (ligne 32)

```yaml
restart_policy:
  condition: none
```

- **Symptôme** : une fois les images corrigées, l'API démarre avant que Postgres soit prêt. Son `init()` échoue et le process s'arrête. Swarm **ne la relance jamais** : le service reste à `0/1` et le site renvoie des erreurs 502 pour toujours.
  ```text
  quickpoll_api   replicated   0/1   127.0.0.1:5000/quickpoll-api:v1
  quickpoll_api.1   qp-manager   Shutdown   Failed 39 seconds ago   "task: non-zero exit (1)"
  init failed: getaddrinfo ENOTFOUND postgres
  ```
- **Correction** : `condition: any` (avec `delay: 5s`, `window: 30s`) et 3 réplicas.
- **Justification** : `depends_on` est ignoré par Swarm. Il n'y a donc aucun ordre de démarrage garanti, et c'est la politique de redémarrage qui doit compenser. Un service sans état comme l'API doit toujours être relancé.

### Problème 3 – Mot de passe en clair (lignes 22, 41, 59)

```yaml
DB_PASSWORD: SuperSecret2026!
POSTGRES_PASSWORD: SuperSecret2026!
```

- **Risque (faille de sécurité)** : le mot de passe est dans le dépôt Git, donc dans tout l'historique. Il est aussi visible par toute personne qui a accès à l'API Docker :
  ```text
  $ docker service inspect quickpoll_postgres --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}'
  ["POSTGRES_DB=quickpoll","POSTGRES_PASSWORD=SuperSecret2026!","POSTGRES_USER=quickpoll"]
  ```
  On le retrouve aussi dans `docker inspect` du conteneur, dans `/proc/<pid>/environ`, et parfois dans les logs.
- **Correction** : un `docker secret` externe, `quickpoll_db_password`, monté dans `/run/secrets/db_password`. On utilise `DB_PASSWORD_FILE` pour l'API et le worker, et `POSTGRES_PASSWORD_FILE` pour Postgres.
- **Justification** : un secret Swarm est chiffré dans le Raft des managers. Il n'est envoyé qu'aux nœuds qui font tourner une tâche autorisée, et il est monté en `tmpfs` (jamais écrit sur le disque du worker). Il n'apparaît plus dans le fichier :
  ```text
  ["POSTGRES_DB=quickpoll","POSTGRES_PASSWORD_FILE=/run/secrets/db_password","POSTGRES_USER=quickpoll"]
  ```

### Problème 4 – Postgres publié sur le port 5432 (ligne 61)

```yaml
ports:
  - "5432:5432"
```

- **Risque (faille de sécurité)** : à cause du routing mesh (voir Q1.1), la base est ouverte sur le port 5432 de **tous** les nœuds, donc depuis l'extérieur du cluster, avec un mot de passe qui est en plus dans le dépôt :
  ```text
  qp-worker1:5432 -> OUVERT
  qp-worker2:5432 -> OUVERT
  ```
- **Correction** : j'ai supprimé `ports:`. Postgres n'est joignable que par le réseau overlay `backend`.
- **Justification** : seuls l'API et le worker ont besoin de la base, et ils y accèdent par le DNS interne (`postgres:5432`). Après correction : `5432 fermé`.

### Problème 5 – Volume Postgres sans placement (lignes 63 + absence de `placement`)

```yaml
volumes:
  - pgdata:/var/lib/postgresql/data
# ... et aucune contrainte de placement
```

- **Risque (perte de données)** : `pgdata` est un volume **local**, il n'existe que sur le nœud où il a été créé. Sans contrainte, Swarm peut placer Postgres sur n'importe quel nœud. Si le nœud tombe, est drainé, ou au prochain déploiement, Postgres repart ailleurs avec un **volume neuf et vide**, et tous les votes sont perdus. Je l'ai observé : au 1er déploiement Postgres était sur `qp-manager`, au 2e il était sur `qp-worker2` avec un autre volume vide :
  ```text
  qp-manager:
  qp-worker1:
  qp-worker2: quickpoll_pgdata
  quickpoll_postgres.1 -> qp-worker2
  ```
- **Correction** : `placement.constraints: [node.labels.db == true]`. Postgres tourne toujours sur `qp-worker1`, donc toujours avec le même volume.
- **Justification** : c'est le rôle du label posé à l'étape 1. Le service à état est attaché au nœud qui porte ses données.

> Autre défaut, traité à l'étape 3 : un seul réseau `quickpoll` pour tout le monde. Le `front`, qui est exposé à Internet, peut donc atteindre directement `redis` et `postgres`.

**Point de contrôle** : `http://localhost:8080` affiche la page et les votes s'enregistrent (voir étape 3).

---

## Étape 3 – Stack production-ready

Le fichier complet : [stack.yml](stack.yml). Voici les exigences et comment je les ai réalisées :

| # | Exigence | Réalisation |
|---|---|---|
| 1 | Aucun secret en clair | secret externe `quickpoll_db_password` + `*_PASSWORD_FILE`. Le secret est créé hors du dépôt : `head -c 24 /dev/urandom \| base64 \| docker secret create quickpoll_db_password -` |
| 2 | Postgres épinglé + accès restreint | `node.labels.db == true`, aucun port publié, uniquement sur le réseau `backend` |
| 3 | Deux réseaux overlay | `frontend` (front + api) et `backend` (api + worker + redis + postgres). `backend` est aussi `internal: true` (pas d'accès sortant) |
| 4 | API : 3 réplicas, healthcheck, restart | `replicas: 3`. Healthcheck `node -e "fetch('http://127.0.0.1:3000/api/health')..."` (Node 22 a `fetch` intégré, pas besoin de curl). `restart_policy: condition: any, delay: 5s` |
| 5 | Tags paramétrables | `${API_TAG:-v1}`, ainsi que `${FRONT_TAG:-v1}`, `${WORKER_TAG:-v1}` et `${REGISTRY:-127.0.0.1:5000}` |

Le healthcheck est réglé ainsi : `interval: 5s, timeout: 3s, retries: 3, start_period: 10s`. Une tâche cassée est donc marquée `unhealthy` en environ 25 s. Cette valeur sert pour régler le `monitor` à l'étape 4.

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

quickpoll_postgres.1     qp-worker1   Running      <- bien sur le noeud db=true
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

> J'ai d'abord testé l'isolation avec `nslookup`, mais la commande renvoie 0 même quand le nom n'existe pas (faux positif). J'ai refait le test avec `getent hosts` et une vraie connexion TCP.

### Question 3.1 – `depends_on` est ignoré : comment garantir que l'API fonctionne si Postgres démarre après elle ?

**Côté Swarm** : on ne cherche pas à imposer un ordre de démarrage, on accepte que les services démarrent dans n'importe quel ordre :
- `restart_policy: condition: any` + `delay` : si l'API s'arrête faute de base, Swarm la relance jusqu'à ce que ça marche (on le voit dans les logs du worker ci-dessus) ;
- `healthcheck` : une tâche qui ne répond pas à `/api/health` (qui fait un `SELECT 1`) est marquée `unhealthy`. Elle ne reçoit pas de trafic pendant un rolling update et elle est remplacée.

**La bonne réponse architecturale** : c'est à **l'application d'être résiliente** à ses dépendances, pas à l'orchestrateur de régler l'ordre de démarrage. Dans un système distribué, Postgres peut aussi tomber, redémarrer ou changer de nœud **pendant** que l'API tourne, pas seulement au démarrage. Un ordre de démarrage ne réglerait donc rien. L'application doit :
- réessayer sa connexion avec un **backoff exponentiel** (et un peu d'aléatoire) au lieu de s'arrêter tout de suite ;
- gérer la perte de connexion pendant qu'elle tourne (le pool `pg` le fait) ;
- avoir un healthcheck différent selon le besoin : *liveness* (le process est vivant) et *readiness* (les dépendances répondent).

Le découplage par Redis va dans ce sens : un vote est accepté (`202`) même si Postgres est momentanément indisponible, et le worker le persistera plus tard.

### Bonus – Retry avec backoff exponentiel ([app/api/server.js](app/api/server.js))

`init()` réessaie maintenant le `CREATE TABLE` jusqu'à 8 fois, avec des délais de 0,5 s, 1 s, 2 s, 4 s, 8 s puis 15 s (plafond). Après le 8e échec, le process s'arrête et c'est la `restart_policy` de Swarm qui prend le relais. `redis.connect()` n'est appelé qu'une fois, après le succès, pour ne pas ouvrir deux fois la même socket. Logs au premier déploiement :

```text
postgres indisponible (getaddrinfo ENOTFOUND postgres), essai 1/8, retry dans 500 ms
postgres indisponible (getaddrinfo ENOTFOUND postgres), essai 2/8, retry dans 1000 ms
postgres indisponible (getaddrinfo ENOTFOUND postgres), essai 3/8, retry dans 2000 ms
postgres indisponible (getaddrinfo ENOTFOUND postgres), essai 4/8, retry dans 4000 ms
postgres indisponible (connect ECONNREFUSED 10.0.2.2:5432), essai 5/8, retry dans 8000 ms
api v1 listening on 3000
```

Le DNS `postgres` finit par répondre (`ENOTFOUND` devient `ECONNREFUSED`), puis Postgres accepte les connexions, et l'API démarre **sans jamais avoir été relancée par Swarm**.

---

## Étape 4 – Rolling update sans coupure

Configuration de l'API :

```yaml
update_config:
  parallelism: 1          # les réplicas sont remplacés un par un
  delay: 5s
  order: start-first      # le nouveau conteneur démarre AVANT l'arrêt de l'ancien
  failure_action: rollback  # un échec déclenche un rollback automatique
  monitor: 30s            # durée d'observation après chaque tâche (> start_period + interval*retries)
  max_failure_ratio: 0    # aucune tâche en échec tolérée
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

**Capture de la sonde pendant le passage v1 → v2** (extraits de [captures/12-sonde-v1-v2.txt](captures/12-sonde-v1-v2.txt)) :

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

**250 requêtes, `ko=0`.** Pendant environ 20 s, v1 et v2 répondent en même temps (les réplicas sont remplacés un par un), puis seuls les 3 nouveaux conteneurs v2 répondent.

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

Swarm est revenu tout seul en v2. Grâce à `start-first`, l'unique tâche v3 n'a jamais remplacé de tâche v2 saine : la sonde n'a reçu **aucune réponse v3** et termine avec **`ko=0`** (214 requêtes, [captures/13-sonde-v3.txt](captures/13-sonde-v3.txt), [captures/13c-rollback.txt](captures/13c-rollback.txt)).

### Question 4.1 – Que se passerait-il avec `order: stop-first` et `replicas: 1` ?

Swarm **arrête d'abord** l'unique conteneur v1, **puis** démarre le v2. Entre les deux, aucune tâche ne sert l'API : le temps d'arrêter l'ancien, de télécharger l'image si besoin, de démarrer Node, de faire `init()` et de passer le healthcheck. Pendant ce temps, nginx renvoie des **502** et la sonde compte des `ko`. Si la nouvelle version est cassée, c'est pire : la coupure dure jusqu'à la fin du rollback.

Pour un service sans état, la mise à jour sans coupure demande donc **au moins 2 réplicas** ou **`start-first`**, et idéalement les deux, comme ici. `stop-first` reste utile quand deux instances ne peuvent pas tourner en même temps, par exemple pour une base de données avec un volume exclusif.

---

## Étape 5 – Chaos

### Drain du nœud le plus chargé (sans Postgres)

10 votes de plus, puis répartition ([captures/14-avant-drain.txt](captures/14-avant-drain.txt)) :

```text
{"results":[{"option":"kubernetes","count":5},{"option":"nomad","count":4},{"option":"swarm","count":6}]}
qp-manager quickpoll_api.1, quickpoll_api.2, quickpoll_worker.1   (+ le registry)
qp-worker1 quickpoll_api.3, quickpoll_front.1, quickpoll_postgres.1
qp-worker2 quickpoll_front.2, quickpoll_redis.1
```

`qp-manager` porte le plus de tâches sans porter Postgres :

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

Les tâches sont redistribuées sur les deux workers, **les 15 votes sont toujours là** et la sonde, qui tournait pendant le drain, termine avec **`ko=0`** (151 requêtes, [captures/15-sonde-drain.txt](captures/15-sonde-drain.txt)). Le port 8080 du manager continue de répondre, alors qu'il ne porte plus aucune tâche : c'est encore le routing mesh.

### Remise en `active` : les tâches reviennent-elles ?

```text
$ docker node update --availability active qp-manager
== 30 s après réactivation, tâches sur qp-manager :
(aucune)
```

**Non.** Swarm ne rééquilibre pas automatiquement. L'orchestrateur ne cherche qu'à respecter l'**état désiré** (3 réplicas d'API, etc.), et cet état est déjà respecté : rien à corriger, donc il ne déplace rien. Déplacer des tâches qui marchent provoquerait des redémarrages inutiles. Le nœud ne sera utilisé que pour les **nouvelles** tâches : nouveau déploiement, mise à jour, panne ailleurs, ou `docker service update --force <svc>` si on veut forcer la redistribution. Après le redéploiement final, on voit d'ailleurs à nouveau des tâches sur `qp-manager` (voir état final).

### Problème réel rencontré : le registry a perdu les images

En vidant `qp-manager`, le **registry** a aussi été déplacé sur `qp-worker2`. Le service `registry:2` avait été créé **sans volume**, comme dans l'énoncé, donc il a redémarré **vide** :

```text
== Catalogue du registry après sa migration sur qp-worker2 :
{"repositories":[]}
```

Le worker a quand même pu redémarrer, uniquement parce que l'image était déjà en cache sur `qp-worker2`. Ensuite, un `docker service update --force quickpoll_api` a échoué avec `failed to resolve reference` : le service est épinglé sur le *digest* de la v2 d'origine, qui n'existait plus nulle part. Le rollback automatique a protégé la production ([captures/15c-registry-apres-drain.txt](captures/15c-registry-apres-drain.txt)).

**Correction** : registry épinglé sur le manager, avec un volume persistant, puis nouveau push des images et nouveau déploiement de la v2 ([captures/17-registry-persistant.txt](captures/17-registry-persistant.txt)) :

```bash
docker service update --constraint-add node.role==manager \
  --mount-add type=volume,source=registry-data,target=/var/lib/registry registry
sh scripts/build-and-push.sh
API_TAG=v2 docker stack deploy -c stack.yml quickpoll
```

C'est le même problème que le problème 5 (un service à état sans volume ni placement), mais pour le registry. En production, on utiliserait un registry externe avec stockage objet (S3) : Docker Hub, GHCR, Harbor…

### Question 5.1 – Le worker est-il idempotent si un vote est rejoué ?

**Oui pour l'écriture en base**, grâce à deux éléments du code :
- l'API génère un identifiant unique `vote_id = crypto.randomUUID()` **avant** de mettre le vote dans Redis : un même vote garde donc le même id s'il est rejoué ;
- la table a `vote_id TEXT UNIQUE NOT NULL`, et le worker insère avec
  ```sql
  INSERT INTO votes (vote_id, option) VALUES ($1, $2) ON CONFLICT (vote_id) DO NOTHING
  ```
  Un vote rejoué tombe sur la contrainte d'unicité et ne fait rien : il n'est **pas compté deux fois**.

**Mais la livraison n'est pas garantie** : le worker fait `BRPOP`, ce qui **retire** le vote de Redis *avant* l'`INSERT`. Si le conteneur est tué entre les deux (drain avec un délai d'arrêt dépassé, crash, OOM), le vote est **perdu**, pas rejoué. Le `SIGTERM` est bien géré (`running = false`, on finit la boucle en cours), donc un drain normal ne perd rien. Pour une livraison « au moins une fois », il faudrait `BLMOVE votes → votes:processing`, puis `LREM` après l'`INSERT` réussi. L'idempotence ci-dessus rendrait alors les rejeux sans danger. Autre point : Redis n'a ni volume ni persistance AOF, donc une file non vidée est perdue si Redis est déplacé.

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

Postgres est arrêté et **ne peut aller nulle part** : aucun autre nœud n'a le label `db=true`. La tâche reste `Pending`. Les healthchecks de l'API (`SELECT 1`) échouent, Swarm relance les tâches API, et **le site est hors service** (502). Les votes envoyés pendant ce temps restent dans Redis s'ils ont pu être reçus. Quand le nœud revient, Postgres redémarre **sur le même volume** et les données sont intactes.

Si j'avais mis le label sur un 2e nœud, Postgres aurait redémarré… **avec un volume vide** : c'est le problème 5.

**Ce que ça montre sur les limites de Swarm pour les services à état :**
- Swarm ne gère **pas le stockage** : un volume `local` est attaché à un nœud, sans réplication ni détachement/rattachement automatique. Il n'y a pas d'équivalent aux PersistentVolumes et StorageClasses de Kubernetes avec CSI, qui permettent de rattacher un disque réseau sur un autre nœud.
- Épingler le service sur un nœud protège les données mais crée un **point unique de défaillance** : on gagne la sécurité des données, on perd la disponibilité.
- Swarm n'a pas de notion d'identité stable ni d'ordre de démarrage (pas d'équivalent aux StatefulSets), et ne sait rien de la réplication primaire/secondaire de Postgres.
- En pratique : base **managée** hors du cluster (RDS, Cloud SQL…), ou volume réseau avec un driver (NFS, Portworx…), ou réplication gérée par la base elle-même (Patroni). Swarm sert alors pour les services **sans état**.

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
quickpoll_postgres.1   postgres:16-alpine    qp-worker1   Running   <- noeud db=true
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

Tous les services sont à `n/n`, les 3 API sont `healthy`, et les 15 votes ont survécu à un rolling update, un rollback, deux drains et un redémarrage de Postgres.

---

## Pour aller plus loin (discussion)

**Swarm face à Kubernetes.** Swarm suffit tant que la stack est surtout faite de services sans état, sur un petit cluster, avec une équipe réduite. Il se lit en 5 minutes, s'appuie sur le format Compose, et le TLS et les secrets sont intégrés. Il ne suffit plus quand on a besoin de :
- **stockage à état** sérieux (CSI, StatefulSets, rattachement de volumes) ;
- **autoscaling** (HPA/VPA, autoscaling des nœuds) ;
- **sondes de readiness et liveness séparées** ;
- **ingress L7** avancé, network policies plus fines que « qui partage quel réseau » ;
- **RBAC** et multi-tenant (namespaces, quotas) ;
- un **écosystème** riche : opérateurs, Helm, GitOps (ArgoCD/Flux), service mesh.

**dev / staging / prod.** Un `stack.yml` de base commun, puis un fichier d'override par environnement, fusionnés à l'appel :
```bash
docker stack deploy -c stack.yml -c stack.prod.yml quickpoll
```
- `stack.yml` : services, réseaux, healthchecks (ce qui est commun) ;
- `stack.dev.yml` : 1 réplica, Postgres publié en local pour le debug, pas de contrainte de placement ;
- `stack.prod.yml` : réplicas, `update_config`, placement, limites de ressources, secrets externes.

Les variables (`API_TAG`, `REGISTRY`) viennent de la CI. On déploie aussi une stack par environnement (`quickpoll-staging`, `quickpoll-prod`), ce qui donne des réseaux et des noms de services séparés, idéalement sur des clusters séparés pour la prod.
