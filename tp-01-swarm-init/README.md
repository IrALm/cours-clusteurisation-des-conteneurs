# TP 1 – Swarm 3 nœuds + résilience

Date : 05/10/2026

Le but du TP est de monter un cluster Docker Swarm avec 1 manager et 2 workers, de lancer un service avec 4 réplicas, puis d'arrêter un worker pour vérifier que Swarm relance les tâches perdues sur les nœuds restants.

Fichiers rendus :

| Fichier | Contenu |
|---|---|
| `README.md` | ce compte rendu |
| [cluster-status-before.txt](cluster-status-before.txt) | état des nœuds et du service avant la panne |
| [cluster-status-after.txt](cluster-status-after.txt) | état des nœuds et du service après la panne |
| [service-ps.txt](service-ps.txt) | historique complet des tâches du service `web`, avec les horodatages |

---

## 1. Topologie du cluster

Je n'avais pas 3 machines à disposition, j'ai donc utilisé la méthode **DinD (Docker-in-Docker)**. Chaque nœud du cluster est un conteneur `docker:dind` qui fait tourner son propre moteur Docker. Les 3 conteneurs sont lancés sur mon PC (Docker Desktop) et reliés par un réseau Docker dédié, `swarm-net`. Pour Swarm, ce sont 3 machines différentes avec chacune son adresse IP.

| Nœud | Rôle | Adresse IP | OS | Docker Engine |
|---|---|---|---|---|
| `manager` | Manager (Leader) | 172.29.0.2 | Alpine Linux 3.24 | 29.8.2 |
| `worker1` | Worker | 172.29.0.3 | Alpine Linux 3.24 | 29.8.2 |
| `worker2` | Worker | 172.29.0.4 | Alpine Linux 3.24 | 29.8.2 |

Machine hôte : Windows 11, Docker Desktop 28.5.1 (backend WSL2, noyau `6.6.87.2-microsoft-standard-WSL2`). Les 3 nœuds partagent ce noyau, puisque ce sont des conteneurs.

```
                 Machine hôte (Windows 11 + Docker Desktop)
   ┌───────────────────────────────────────────────────────────────┐
   │                    réseau Docker "swarm-net"                  │
   │                                                               │
   │   ┌────────────┐      ┌────────────┐      ┌────────────┐      │
   │   │  manager   │      │  worker1   │      │  worker2   │      │
   │   │ 172.29.0.2 │◄────►│ 172.29.0.3 │      │ 172.29.0.4 │      │
   │   │  (Leader)  │◄─────┼────────────┼─────►│            │      │
   │   │ docker:dind│      │ docker:dind│      │ docker:dind│      │
   │   └────────────┘      └────────────┘      └────────────┘      │
   └───────────────────────────────────────────────────────────────┘
```

Création des 3 nœuds :

```bash
docker network create swarm-net
docker run -d --privileged --name manager --hostname manager --network swarm-net docker:dind
docker run -d --privileged --name worker1 --hostname worker1 --network swarm-net docker:dind
docker run -d --privileged --name worker2 --hostname worker2 --network swarm-net docker:dind
```

L'option `--privileged` est obligatoire : un moteur Docker a besoin d'accès étendus au noyau (cgroups, réseau…) pour pouvoir lancer des conteneurs à son tour.

Ensuite, toutes les commandes Swarm sont lancées *dans* les nœuds avec `docker exec <nœud> docker ...`.

---

## 2. Initialisation du Swarm (manager)

Commande exacte :

```bash
docker exec manager docker swarm init --advertise-addr 172.29.0.2
```

```text
Swarm initialized: current node (pj07363c4mno1ciweisizv933) is now a manager.

To add a worker to this swarm, run the following command:

    docker swarm join --token SWMTKN-1-5q4onbz6h3k****************************-cfyu5nvb**************** 172.29.0.2:2377

To add a manager to this swarm, run 'docker swarm join-token manager' and follow the instructions.
```

`--advertise-addr` indique l'adresse IP que le manager donne aux autres nœuds pour le joindre. Je l'ai précisée pour qu'il annonce bien son IP sur `swarm-net`.

Le port `2377` est celui de la gestion du cluster : les workers s'y connectent pour rejoindre le Swarm et recevoir leurs tâches.

## 3. Ajout des workers

Commande exacte, lancée sur `worker1` puis sur `worker2` (token masqué) :

```bash
docker exec worker1 docker swarm join --token SWMTKN-1-5q4onbz6h3k****************************-cfyu5nvb**************** 172.29.0.2:2377
docker exec worker2 docker swarm join --token SWMTKN-1-5q4onbz6h3k****************************-cfyu5nvb**************** 172.29.0.2:2377
```

```text
This node joined a swarm as a worker.
```

J'ai masqué le token parce que n'importe qui qui le possède peut ajouter une machine au cluster. Si un token a fuité, on peut le changer avec `docker swarm join-token --rotate worker`. Il existe 2 tokens différents : un pour rejoindre en tant que worker et un pour rejoindre en tant que manager. On les récupère avec `docker swarm join-token worker` (ou `manager`) sur le manager.

Vérification :

```text
$ docker exec manager docker node ls
ID                            HOSTNAME   STATUS    AVAILABILITY   MANAGER STATUS   ENGINE VERSION
pj07363c4mno1ciweisizv933 *   manager    Ready     Active         Leader           29.8.2
h0m8dk1epnyx0x039tdoxkf9b     worker1    Ready     Active                          29.8.2
qs7nm0to33s1istwrsne0x21e     worker2    Ready     Active                          29.8.2
```

Les 3 nœuds sont `Ready`. Le manager est `Leader` et la colonne est vide pour les workers.

---

## 4. Création du service

```bash
docker exec manager docker service create --name web --replicas 4 nginx
```

Le service est passé à `4/4` en une quinzaine de secondes, le temps que chaque nœud télécharge l'image nginx.

### Répartition initiale

Extrait de [cluster-status-before.txt](cluster-status-before.txt) :

```text
$ docker exec manager docker service ps web
ID             NAME      IMAGE          NODE      DESIRED STATE   CURRENT STATE            ERROR     PORTS
bzy98vi9nsup   web.1     nginx:latest   worker1   Running         Running 10 seconds ago
668phlrw9rko   web.2     nginx:latest   worker1   Running         Running 11 seconds ago
n1howl81rzsk   web.3     nginx:latest   worker2   Running         Running 9 seconds ago
21c56l1f7ju8   web.4     nginx:latest   manager   Running         Running 11 seconds ago
```

| Nœud | Tâches |
|---|---|
| manager | web.4 |
| worker1 | web.1, web.2 |
| worker2 | web.3 |

Par défaut, un manager est aussi un nœud de travail : il a donc reçu une tâche lui aussi. Avec 4 tâches pour 3 nœuds, l'un d'eux en a forcément 2, et ici c'est `worker1`.

---

## 5. Simulation de la panne

J'ai choisi d'arrêter **worker1**, puisque c'est lui qui portait 2 des 4 réplicas.

Pour simuler la panne, j'ai arrêté le conteneur qui joue le rôle de la machine :

```bash
docker stop worker1      # lancé à 12:04:49 (heure locale) = 10:04:49 UTC
```

Comme le nœud est un conteneur, `docker stop` revient à éteindre la machine : le moteur Docker de worker1 et tous les conteneurs nginx qu'il faisait tourner s'arrêtent d'un coup. Pour le manager, worker1 cesse simplement de répondre, comme lors d'une vraie coupure.

---

## 6. État après la panne

Extrait de [cluster-status-after.txt](cluster-status-after.txt) :

```text
$ docker exec manager docker node ls
ID                            HOSTNAME   STATUS    AVAILABILITY   MANAGER STATUS   ENGINE VERSION
pj07363c4mno1ciweisizv933 *   manager    Ready     Active         Leader           29.8.2
h0m8dk1epnyx0x039tdoxkf9b     worker1    Down      Active                          29.8.2
qs7nm0to33s1istwrsne0x21e     worker2    Ready     Active                          29.8.2

$  docker exec manager docker service ps web --filter desired-state=running
ID             NAME      IMAGE          NODE      DESIRED STATE   CURRENT STATE                ERROR     PORTS
xpsbb05ngj6j   web.1     nginx:latest   worker2   Running         Running 23 seconds ago
uae30boc5j29   web.2     nginx:latest   manager   Running         Running 23 seconds ago
n1howl81rzsk   web.3     nginx:latest   worker2   Running         Running 59 seconds ago
21c56l1f7ju8   web.4     nginx:latest   manager   Running         Running about a minute ago
```

Historique complet ([service-ps.txt](service-ps.txt)) :

```text
$ docker exec manager docker service ps web
ID             NAME        IMAGE          NODE      DESIRED STATE   CURRENT STATE                ERROR     PORTS
xpsbb05ngj6j   web.1       nginx:latest   worker2   Running         Running 24 seconds ago
bzy98vi9nsup    \_ web.1   nginx:latest   worker1   Shutdown        Running about a minute ago
uae30boc5j29   web.2       nginx:latest   manager   Running         Running 24 seconds ago
668phlrw9rko    \_ web.2   nginx:latest   worker1   Shutdown        Running about a minute ago
n1howl81rzsk   web.3       nginx:latest   worker2   Running         Running 59 seconds ago
21c56l1f7ju8   web.4       nginx:latest   manager   Running         Running about a minute ago
```

| Nœud | Avant | Après |
|---|---|---|
| manager | web.4 | web.4, **web.2** |
| worker1 | web.1, web.2 | *(Down)* |
| worker2 | web.3 | web.3, **web.1** |

---

## 7. Analyse

### Les 4 réplicas ont-ils été restaurés ?

Oui. Worker1 est passé en `Down` et ses 2 tâches (`web.1` et `web.2`) ont été recréées automatiquement : `web.1` sur worker2 et `web.2` sur le manager. Je n'ai rien eu à faire, le service est revenu à 4 réplicas en fonctionnement.

Dans l'historique, les anciennes tâches restent visibles avec le préfixe `\_` et un état désiré `Shutdown`. Swarm ne « déplace » pas une tâche : il abandonne l'ancienne et en crée une nouvelle (nouvel ID) dans le même *slot* (`web.1`, `web.2`).

### En combien de temps ?

J'ai reconstitué la chronologie avec l'heure de ma commande `docker stop`, l'heure d'arrêt du conteneur (`docker inspect worker1`) et les horodatages des tâches (`docker inspect <id_tâche>`, voir la fin de [service-ps.txt](service-ps.txt)) :

| Heure (UTC) | Écart | Événement |
|---|---|---|
| 10:04:49.4 | 0 s | `docker stop worker1` |
| 10:04:50.6 | +1,2 s | worker1 est complètement arrêté |
| 10:05:01.5 | +12,1 s | Swarm a détecté la panne et crée les 2 nouvelles tâches |
| 10:05:06.8 | **+17,4 s** | les 2 nouvelles tâches sont `Running` : retour à 4 réplicas |

Le service a donc été rétabli en **environ 17 secondes**. Ce temps se décompose en deux parties :
- **environ 11 s pour détecter la panne.** Le manager ne sait pas qu'un nœud est mort : il le déduit quand le nœud arrête d'envoyer ses *heartbeats* (signaux réguliers « je suis vivant », toutes les 5 s par défaut). Après plusieurs heartbeats manqués, le nœud est déclaré `Down`.
- **environ 5 s pour démarrer les nouveaux conteneurs.** L'image nginx était déjà présente sur worker2 et sur le manager, donc il n'y a pas eu de téléchargement. Sinon le délai aurait été plus long.

Pendant ces 17 secondes, le service tournait avec seulement 2 réplicas sur 4. Il était dégradé mais toujours disponible, puisque `web.3` et `web.4` n'ont jamais été arrêtés.

### Remarque : le « 6/4 » de docker service ls

Juste après la panne, `docker service ls` affichait :

```text
ID             NAME      MODE         REPLICAS   IMAGE          PORTS
k70iweco6ldf   web       replicated   6/4        nginx:latest
```

Il n'y a pas vraiment 6 conteneurs. Le manager n'arrive plus à joindre worker1, donc il ne peut pas confirmer que ses 2 anciennes tâches sont arrêtées. Il garde leur dernier état connu (`Running`) et les compte en plus des 4 nouvelles. Dans `docker service ps`, on voit d'ailleurs que leur état *désiré* est bien `Shutdown`. Quand worker1 est revenu (voir plus bas), il a confirmé que ces tâches étaient arrêtées et le compteur est repassé à `4/4`.

### Bonus : que se passe-t-il quand worker1 revient ?

J'ai redémarré worker1 avec `docker start worker1` :

```text
$ docker node ls
worker1    Ready     Active                          29.8.2

$ docker service ps web --filter desired-state=running
NAME      NODE      CURRENT STATE
web.1     worker2   Running 50 seconds ago
web.2     manager   Running 50 seconds ago
web.3     worker2   Running about a minute ago
web.4     manager   Running about a minute ago
```

Worker1 repasse en `Ready`, mais **aucune tâche ne revient dessus** : 0 conteneur nginx sur worker1. Swarm ne rééquilibre pas automatiquement un service qui fonctionne déjà, pour ne pas couper des conteneurs sains sans raison. Pour répartir à nouveau les tâches, il faut le demander :

```text
$ docker service update --force web
NAME      NODE      CURRENT STATE
web.1     manager   Running 21 seconds ago
web.2     worker1   Running 23 seconds ago
web.3     worker2   Running 20 seconds ago
web.4     manager   Running 18 seconds ago
```

`--force` recrée toutes les tâches une par une (*rolling update*), et worker1 en récupère une.

---

## 8. Et si on avait perdu le manager ?

### Ce que j'ai observé

J'ai fait le test en arrêtant le manager (`docker stop manager`) :

```text
--- conteneurs nginx toujours actifs sur les workers :
worker1: web.2.v751usdyzaalis9xisje50o9h Up 50 seconds
worker2: web.3.vifj2rg3k4q0pi51oh4ij0kae Up 47 seconds

--- tentative de gestion depuis worker1 :
$ docker node ls
Error response from daemon: This node is not a swarm manager. Worker nodes can't be used to view or modify cluster state.
$ docker service scale web=6
web: Error response from daemon: This node is not a swarm manager. ...
```

1. **Les conteneurs des workers continuent de tourner.** Les workers n'ont pas besoin du manager pour faire tourner ce qu'ils ont déjà, donc le service reste en partie disponible.
2. **Les 2 réplicas qui étaient sur le manager sont perdus et ne sont pas recréés.** C'est justement le manager qui s'occupe de replanifier les tâches. Sans lui, personne ne le fait, et le service reste à 2 réplicas sur 4.
3. **On ne peut plus du tout gérer le cluster.** Impossible de lister les nœuds, de créer, modifier ou scaler un service. Les workers refusent ces commandes.
4. Si un worker tombait en plus à ce moment-là, ses tâches ne seraient pas replanifiées non plus.

Après `docker start manager`, le cluster est revenu à la normale (`4/4`) : l'état du Swarm est enregistré sur le disque du manager, qui a relancé ses tâches au redémarrage. Si le disque du manager avait été perdu, le cluster aurait été perdu aussi. Il aurait fallu tout recréer (`swarm init`, nouveaux `join`, recréer les services) ou restaurer une sauvegarde de `/var/lib/docker/swarm`.

### Pourquoi, et comment l'éviter

Avec un seul manager, le manager est un **point unique de défaillance**  pour la gestion du cluster.

En production, on met **plusieurs managers**, toujours en **nombre impair** (3 ou 5). Ils se mettent d'accord sur l'état du cluster avec l'algorithme **Raft**, qui demande une **majorité** (quorum) de managers disponibles :

| Nombre de managers | Majorité nécessaire | Pannes de managers tolérées |
|---|---|---|
| 1 | 1 | 0 (notre cas) |
| 3 | 2 | 1 |
| 5 | 3 | 2 |

Avec 3 managers, si le Leader tombe, les 2 autres élisent un nouveau Leader en quelques secondes et le cluster continue de fonctionner normalement. Si on perd la majorité, on se retrouve dans la même situation que dans mon test : les conteneurs tournent, mais on ne peut plus rien gérer.

Dans notre cluster, on pourrait passer à 3 managers avec :

```bash
docker exec manager docker node promote worker1 worker2
```

(Dans ce cas il n'y aurait plus de « vrais » workers. En général, on garde des managers dédiés et on ajoute des workers à côté.)

---

## 9. Nettoyage

Pour supprimer l'environnement du TP :

```bash
docker rm -f -v manager worker1 worker2   # -v supprime aussi les volumes anonymes créés par docker:dind
docker network rm swarm-net
```

## Ce que je retiens

- Swarm compare en permanence l'**état désiré** (4 réplicas) à l'**état réel**, et corrige tout seul l'écart quand un nœud tombe.
- La détection d'une panne n'est pas immédiate : elle repose sur les heartbeats, d'où une dizaine de secondes avant la réaction.
- Swarm ne rééquilibre pas tout seul quand un nœud revient. Il faut un `docker service update --force`.
- Les workers sont remplaçables, mais avec un seul manager le cluster ne se gère plus si ce manager tombe. Il en faut 3 (ou 5) pour être vraiment résilient.
