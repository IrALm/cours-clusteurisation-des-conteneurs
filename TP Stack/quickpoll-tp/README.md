# TP — QuickPoll : déployer une stack multi-services sur Docker Swarm

## Contexte

Vous reprenez **QuickPoll**, une application de sondage composée de 5 services :

| Service    | Rôle                                                   | Image            |
|------------|--------------------------------------------------------|------------------|
| `front`    | Nginx : sert la page et proxifie `/api/*` vers l'API    | maison           |
| `api`      | Node.js : reçoit les votes, expose les résultats        | maison           |
| `worker`   | Node.js : dépile les votes de Redis vers Postgres       | maison           |
| `redis`    | File d'attente des votes                               | `redis:7-alpine` |
| `postgres` | Persistance des votes                                  | `postgres:16-alpine` |

```
navigateur ──> front ──> api ──LPUSH──> redis ──BRPOP──> worker ──> postgres
                          └──────────── SELECT ─────────────────────────┘
```

L'ancien développeur a laissé un `stack.yml` « qui marchait sur son poste avec `docker compose up` ». Votre mission : faire tourner QuickPoll **en production** sur un cluster Swarm de 3 nœuds, avec des mises à jour sans interruption de service.

> Vous ne devez **pas** modifier le code applicatif dans `app/`, sauf pour le bonus de l'étape 3.

## Prérequis

- 3 machines avec Docker (VMs, ou [Play with Docker](https://labs.play-with-docker.com) : 3 instances)
- Ce dépôt cloné sur le nœud qui deviendra manager

---

## Étape 1 — Monter le cluster (10 min)

1. Sur le premier nœud, initialisez le Swarm :
   ```sh
   docker swarm init --advertise-addr <IP_DU_NOEUD>
   ```
2. Joignez les deux autres nœuds en **workers** avec la commande affichée.
3. Vérifiez : `docker node ls` doit afficher 3 nœuds `Ready`.
4. Choisissez un worker qui hébergera la base et posez-lui un label :
   ```sh
   docker node update --label-add db=true <NOM_DU_NOEUD>
   ```
5. Déployez un registry privé dans le cluster, puis construisez et poussez les images :
   ```sh
   docker service create --name registry --publish 5000:5000 registry:2
   ./scripts/build-and-push.sh
   ```
   Le script pousse `quickpoll-front:v1`, `quickpoll-worker:v1` et trois versions de l'API (`v1`, `v2`, `v3`) dans `127.0.0.1:5000`.

**Question 1.1** — Pourquoi `127.0.0.1:5000` est-il joignable depuis *tous* les nœuds, alors que le registry ne tourne que sur l'un d'eux ?

---

## Étape 2 — Déboguer le `stack.yml` (15 min)

Tentez un premier déploiement :

```sh
docker stack deploy -c stack.yml quickpoll
docker stack services quickpoll
docker service ps quickpoll_api --no-trunc
```

Ça ne fonctionne pas. Le fichier contient **5 problèmes** : certains empêchent le démarrage, d'autres ne se verront qu'en production (perte de données, faille de sécurité).

Pour chaque problème, notez dans `RENDU.md` :
- la ligne fautive,
- le symptôme observé (ou le risque, s'il n'est pas visible),
- votre correction et sa justification.

Outils utiles : `docker service ps <svc> --no-trunc`, `docker service logs <svc>`, `docker stack config -c stack.yml`, la [référence Compose pour le déploiement](https://docs.docker.com/reference/compose-file/deploy/).

**Point de contrôle** : `http://<IP_D_UN_NOEUD>:8080` affiche la page et les votes s'enregistrent.

---

## Étape 3 — Rendre la stack production-ready (15 min)

Complétez votre `stack.yml` pour respecter les exigences suivantes :

1. **Aucun secret en clair** dans le fichier. Utilisez un `docker secret` (l'API, le worker et l'image Postgres savent lire une variable `*_FILE`).
2. **Postgres** est épinglé sur le nœud labellisé `db=true` et n'est joignable que par les services qui en ont besoin.
3. **Deux réseaux overlay** : `front` ne doit pas pouvoir atteindre `postgres` ni `redis`.
4. **API** : 3 réplicas, un `healthcheck` sur `/api/health` (l'image ne contient pas `curl`, mais elle contient `node`), et une politique de redémarrage qui tolère un Postgres pas encore prêt.
5. Les tags d'images doivent être paramétrables (`${API_TAG:-v1}`) pour la suite.

**Question 3.1** — `depends_on` est ignoré par `docker stack deploy`. Comment garantissez-vous que l'API fonctionne quand Postgres démarre après elle ? Quelle est la bonne réponse *architecturale*, au-delà de la configuration Swarm ?

**Bonus** — Implémentez un retry avec backoff exponentiel dans `app/api/server.js` (fonction `init`).

---

## Étape 4 — Rolling update sans coupure (12 min)

1. Dans un second terminal, lancez la sonde :
   ```sh
   ./scripts/curl-loop.sh http://<IP_D_UN_NOEUD>:8080
   ```
2. Ajoutez à l'API un `update_config` et un `rollback_config` afin que :
   - les réplicas soient remplacés un par un,
   - le nouveau conteneur démarre **avant** l'arrêt de l'ancien,
   - un échec déclenche un **rollback automatique**.
3. Déployez la v2 :
   ```sh
   API_TAG=v2 docker stack deploy -c stack.yml quickpoll
   ```
   La sonde doit passer de `v1` à `v2` avec **`ko=0`**.
4. Déployez la v3, volontairement cassée (son `/api/health` renvoie 500) :
   ```sh
   API_TAG=v3 docker stack deploy -c stack.yml quickpoll
   watch docker service ps quickpoll_api
   ```
   Swarm doit revenir seul en v2. Vérifiez avec `docker service inspect quickpoll_api --format '{{.UpdateStatus.State}}'`.

**Question 4.1** — Que se passerait-il pendant la mise à jour avec `order: stop-first` et `replicas: 1` ?

---

## Étape 5 — Chaos (8 min)

1. Votez une dizaine de fois.
2. Videz le nœud qui porte le plus de tâches **sans** porter Postgres :
   ```sh
   docker node update --availability drain <NOM_DU_NOEUD>
   ```
3. Observez la redistribution (`docker stack ps quickpoll`) et vérifiez que les votes sont toujours là.
4. Remettez le nœud en `active`. Les tâches reviennent-elles d'elles-mêmes ? Pourquoi ?

**Question 5.1** — Le worker est-il idempotent si un vote est rejoué après un drain ? Justifiez à partir du code de `app/worker/worker.js`.

**Question 5.2** — Que se passe-t-il si vous videz le nœud `db=true` ? Qu'est-ce que cela dit des limites de Swarm pour les services stateful ?

---

## Rendu

Un dépôt (ou une archive) contenant :
- `stack.yml` corrigé et complété,
- `RENDU.md` : les 5 problèmes de l'étape 2, les réponses aux questions, une capture de la sonde pendant le passage v1 → v2.

## Pour aller plus loin (discussion)

- Swarm face à Kubernetes : à partir de quand Swarm ne suffit-il plus ?
- Comment géreriez-vous dev / staging / prod avec plusieurs stacks et des fichiers d'override (`docker stack deploy -c stack.yml -c stack.prod.yml`) ?
