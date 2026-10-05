# TP 1 – Prise en main de Docker

Date : 05/10/2026

Machine utilisée : PC sous Windows 11 avec Docker Desktop (version 28.5.1, backend WSL2).

Les sorties de terminal dans ce rapport sont des copier-coller de ce que j'ai obtenu pendant le TP.

---

## 1. Installation et vérification

Docker Desktop était déjà installé sur ma machine, donc j'ai commencé directement par les vérifications.

Au premier `docker version`, je n'avais que la partie "Client" et une erreur :

```text
error during connect: ... open //./pipe/dockerDesktopLinuxEngine: Le fichier spécifié est introuvable.
```

En fait Docker Desktop n'était pas lancé, donc le moteur Docker (la partie "Server") ne répondait pas. Après avoir démarré Docker Desktop, tout fonctionnait :

```text
> docker version --format 'Client {{.Client.Version}} / Server {{.Server.Version}}'
Client 28.5.1 / Server 28.5.1
```

J'ai compris à ce moment-là que la commande `docker` n'est qu'un client qui envoie des ordres au démon Docker. Sous Windows, ce démon tourne dans une VM Linux (WSL2) gérée par Docker Desktop.

### docker run hello-world

```text
> docker run hello-world
Unable to find image 'hello-world:latest' locally
latest: Pulling from library/hello-world
4f55086f7dd0: Pull complete
Digest: sha256:5e23090353324d887c48ad5e5c56d294eab81588df9605b07d1afe895f9cc8f8
Status: Downloaded newer image for hello-world:latest

Hello from Docker!
This message shows that your installation appears to be working correctly.

To generate this message, Docker took the following steps:
 1. The Docker client contacted the Docker daemon.
 2. The Docker daemon pulled the "hello-world" image from the Docker Hub.
    (amd64)
 3. The Docker daemon created a new container from that image which runs the
    executable that produces the output you are currently reading.
 4. The Docker daemon streamed that output to the Docker client, which sent it
    to your terminal.

To try something more ambitious, you can run an Ubuntu container with:
 $ docker run -it ubuntu bash

Share images, automate workflows, and more with a free Docker ID:
 https://hub.docker.com/

For more examples and ideas, visit:
 https://docs.docker.com/get-started/
```

L'image n'était pas présente en local, donc Docker l'a téléchargée depuis Docker Hub, puis il a créé un conteneur qui a affiché ce message. Comme le programme s'arrête juste après, le conteneur passe directement en statut `Exited`.

---

## 2. Premier conteneur : Nginx

```bash
docker run --name web1 -p 8080:80 -d nginx:alpine
```

- `--name web1` : donne un nom au conteneur (sinon Docker en invente un).
- `-p 8080:80` : le port 8080 de mon PC est redirigé vers le port 80 du conteneur.
- `-d` : le conteneur tourne en arrière-plan.
- `nginx:alpine` : l'image nginx, version basée sur Alpine Linux (plus légère).

```text
> docker ps
CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS         PORTS                                     NAMES
4658a8d886fb   nginx:alpine   "/docker-entrypoint.…"   2 seconds ago   Up 2 seconds   0.0.0.0:8080->80/tcp, [::]:8080->80/tcp   web1
```

En ouvrant `http://localhost:8080`, j'ai bien la page "Welcome to nginx!".

Ensuite j'ai testé stop / start :

```text
> docker stop web1
> docker ps -a --filter name=web1
web1 Exited (0) Less than a second ago
> docker start web1
web1 Up Less than a second
```

Après le `start`, c'est le même conteneur qui repart (même ID `4658a8d886fb`). Il n'en recrée pas un nouveau.

---

## 3. MySQL et persistance des données

L'idée de cette partie : quand on supprime un conteneur, tout ce qu'il a écrit dans son système de fichiers est perdu. Pour une base de données ce n'est pas acceptable, donc on stocke `/var/lib/mysql` en dehors du conteneur avec un volume.

### A/B. Avec un dossier de mon PC (bind mount)

Sous PowerShell :

```powershell
mkdir mysql-data
docker run --name mysql1 -d `
  -e MYSQL_ROOT_PASSWORD=root `
  -e MYSQL_DATABASE=tp `
  -p 3306:3306 `
  -v "${PWD}\mysql-data:/var/lib/mysql" `
  mysql:8
```

Les `-e` passent des variables d'environnement que l'image MySQL utilise au premier lancement (mot de passe root et création de la base `tp`). Le `-v` monte mon dossier `mysql-data` à la place de `/var/lib/mysql` dans le conteneur.

Extrait de `docker logs -f mysql1` :

```text
[Note] [Entrypoint]: Initializing database files
... /usr/sbin/mysqld (mysqld 8.4.11) initializing of server in progress as process 81
... /usr/sbin/mysqld: ready for connections. Version: '8.4.11' ... port: 0
... /usr/sbin/mysqld: ready for connections. Version: '8.4.11' ... port: 3306
```

J'ai remarqué que "ready for connections" apparaît deux fois. La première fois avec `port: 0` : c'est un serveur temporaire que l'image lance pour faire l'initialisation. Le vrai serveur est prêt seulement à la deuxième ligne, avec `port: 3306`.

### C. Fichiers créés sur mon PC

```text
> Get-ChildItem mysql-data       (équivalent PowerShell de ls -la)
d-----          #innodb_redo
d-----          #innodb_temp
d-----          mysql
d-----          performance_schema
d-----          sys
-a---- 12582912 ibdata1
-a---- 27262976 mysql.ibd
-a---- 16777216 undo_001
-a---- 16777216 undo_002
...
```

On retrouve bien les fichiers MySQL (`mysql`, `performance_schema`, `ibdata1`…) directement dans mon dossier.

### D. Test de persistance

Pour vérifier que les données restent vraiment, j'ai créé une table avec deux lignes avant de supprimer le conteneur :

```text
> docker exec mysql1 mysql -uroot -proot tp -e "CREATE TABLE etudiants(id INT PRIMARY KEY AUTO_INCREMENT, nom VARCHAR(50));
                                                INSERT INTO etudiants(nom) VALUES ('Alice'),('Bob'); SELECT * FROM etudiants;"
id  nom
1   Alice
2   Bob
```

Puis j'ai supprimé le conteneur et j'en ai relancé un nouveau avec le même dossier :

```text
> docker rm -f mysql1
> docker run --name mysql1 -d -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=tp -p 3306:3306 -v "${PWD}\mysql-data:/var/lib/mysql" mysql:8

> docker exec mysql1 mysql -uroot -proot tp -e "SELECT * FROM etudiants;"
id  nom
1   Alice
2   Bob
```

Les données sont toujours là. Dans les logs du nouveau conteneur, il n'y a plus la ligne "Initializing database files" : MySQL a vu que le dossier contenait déjà une base et ne l'a pas réinitialisée. Il a d'ailleurs démarré beaucoup plus vite (environ 3 s au lieu de 10 s).

### E. Avec un volume nommé

```text
> docker volume create mysql_data
> docker run --name mysql2 -d -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=tp -p 3307:3306 -v mysql_data:/var/lib/mysql mysql:8
> docker volume inspect mysql_data
[
    {
        "CreatedAt": "2026-10-05T08:38:11Z",
        "Driver": "local",
        "Mountpoint": "/var/lib/docker/volumes/mysql_data/_data",
        "Name": "mysql_data",
        "Scope": "local"
    }
]
```

J'ai dû mettre `-p 3307:3306` car le port 3306 de mon PC était déjà utilisé par `mysql1`.

Le chemin `Mountpoint` n'existe pas sur mon disque Windows, il est dans la VM de Docker Desktop. Pour voir quand même ce qu'il y a dedans, j'ai monté le volume dans un petit conteneur Alpine :

```text
> docker run --rm -v mysql_data:/data alpine ls /data
#innodb_redo  auto.cnf  ibdata1  mysql  mysql.ibd  performance_schema  sys  tp  undo_001 ...
```

Ce que je retiens sur la différence entre les deux :
- le bind mount, c'est un dossier que je choisis sur mon PC, je peux voir les fichiers directement ;
- le volume nommé est géré par Docker, je ne le vois pas dans mes dossiers mais il est plus simple à utiliser (pas de chemin à gérer) et plus rapide sous Windows.

---

## 4. Commandes de base

J'ai testé les commandes suivantes sur `web1` :

| Commande | Ce que ça fait |
|---|---|
| `docker ps` | liste les conteneurs qui tournent |
| `docker ps -a` | liste tous les conteneurs, même arrêtés |
| `docker logs web1` | affiche les logs du conteneur |
| `docker logs -f web1` | suit les logs en direct (Ctrl+C pour quitter) |
| `docker stop / start / restart web1` | arrête, démarre, redémarre |
| `docker rm web1` | supprime un conteneur arrêté |
| `docker rm -f web1` | le force à s'arrêter puis le supprime |
| `docker images` | liste les images téléchargées |
| `docker rmi nginx:alpine` | supprime une image |

Extrait de `docker images` :

```text
REPOSITORY   TAG       IMAGE ID       SIZE
mysql        8         6ea90827b110   1.11GB
nginx        alpine    df221db836e1   93.5MB
nginx        latest    05b8cb60c354   250MB
alpine       latest    294b683cb724   12.9MB
hello-world  latest    5e2309035332   20.4kB
```

On voit bien l'intérêt de la version alpine : 93,5 Mo au lieu de 250 Mo pour nginx.

Je n'ai pas lancé `docker system prune`. J'ai d'autres projets Docker sur mon PC et cette commande supprime tous les conteneurs arrêtés, pas seulement ceux du TP. J'ai préféré supprimer mes conteneurs un par un avec `docker rm`.

---

## 5. Introspection d'un conteneur

### docker inspect

`docker inspect web1` affiche un gros JSON avec toute la configuration du conteneur. Pour récupérer juste l'IP :

```text
> docker inspect -f '{{.NetworkSettings.IPAddress}}' web1
172.17.0.2
```

Remarque : dans l'énoncé la commande est écrite `-f '.NetworkSettings.IPAddress'`, sans les accolades. Ça ne marche pas tel quel, il faut écrire `'{{.NetworkSettings.IPAddress}}'`.

J'ai aussi regardé d'autres infos :

```text
> docker inspect -f 'Image={{.Config.Image}} | Cmd={{.Config.Cmd}} | Entrypoint={{.Config.Entrypoint}}' web1
Image=nginx:alpine | Cmd=[nginx -g daemon off;] | Entrypoint=[/docker-entrypoint.sh]

> docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' web1
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NGINX_VERSION=1.31.6
...

> docker port web1
80/tcp -> 0.0.0.0:8080
```

Je me suis demandé pourquoi nginx était lancé avec `daemon off`. Un conteneur reste en vie tant que son processus principal tourne. Si nginx passait en arrière-plan, le processus principal se terminerait et le conteneur s'arrêterait directement.

### docker top et docker exec

```text
> docker top web1
UID      PID    PPID   CMD
root     2925   2903   nginx: master process nginx -g daemon off;
statd    2963   2925   nginx: worker process
statd    2964   2925   nginx: worker process
...
```

```text
> docker exec -it web1 sh
/ # uname -a
Linux 4658a8d886fb 6.6.87.2-microsoft-standard-WSL2 ... x86_64 Linux
/ # ps aux
PID   USER     COMMAND
    1 root     nginx: master process nginx -g daemon off;
   22 nginx    nginx: worker process
   ...
/ # ls -la /usr/share/nginx/html
-rw-r--r--  1 root root  497  50x.html
-rw-r--r--  1 root root  896  index.html
/ # exit
```

Ce que j'ai observé en comparant les deux :
- `uname -a` dans le conteneur affiche le noyau WSL2 de ma machine. Le conteneur n'a pas son propre noyau, il partage celui de l'hôte, contrairement à une VM.
- Le processus nginx principal a le PID 2925 avec `docker top` (vu depuis l'hôte), mais le PID 1 avec `ps aux` (vu depuis le conteneur). C'est le même processus. Le conteneur a sa propre numérotation des processus.
- Les workers apparaissent sous l'utilisateur `statd` d'un côté et `nginx` de l'autre. C'est le même numéro d'utilisateur (101), mais il ne porte pas le même nom dans la VM et dans le conteneur.

### docker stats

```text
> docker stats --no-stream web1
NAME   CPU %   MEM USAGE / LIMIT    MEM %   NET I/O      PIDS
web1   0.00%   12.66MiB / 15.3GiB   0.08%   610B / 84B   17
```

Nginx consomme très peu (12 Mo de RAM). Sans `--no-stream`, l'affichage se met à jour en continu.

### docker diff

J'ai aussi testé `docker diff`, qui montre ce que le conteneur a modifié par rapport à l'image (A = ajouté, C = modifié) :

```text
> docker diff web1
C /etc/nginx/conf.d/default.conf
A /run/nginx.pid
A /var/cache/nginx/client_temp
...
```

### docker cp

```text
> docker cp web1:/etc/nginx/nginx.conf ./nginx.conf
```

Le fichier de config de nginx a bien été copié sur mon PC.

---

## 6. Création de mon image

Fichiers dans le dossier `tp-docker-image/` :

[index.html](index.html)

```html
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>Mon site Docker</title>
  </head>
  <body>
    <h1>Hello depuis mon image Docker</h1>
    <p>Buildé localement.</p>
  </body>
</html>
```

[Dockerfile](Dockerfile)

```dockerfile
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
```

- `FROM` : je pars de l'image nginx:alpine, donc j'ai déjà un serveur web prêt.
- `COPY` : je remplace la page par défaut de nginx par la mienne.

J'ai aussi ajouté un [.dockerignore](.dockerignore) pour que le rapport et le Dockerfile ne soient pas envoyés dans le contexte de build (ils ne servent à rien dans l'image).

### Build

```text
> docker build -t monsite:1.0 .
#0 building with "desktop-linux" instance using docker driver

#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 104B 0.0s done
#1 DONE 0.0s

#2 [internal] load metadata for docker.io/library/nginx:alpine
#2 DONE 0.0s

#3 [internal] load .dockerignore
#3 transferring context: 70B done
#3 DONE 0.0s

#4 [internal] load build context
#4 transferring context: 246B done
#4 DONE 0.0s

#5 [1/2] FROM docker.io/library/nginx:alpine@sha256:df221db836e1754089190208cee7eeda94f233197056426eda74a43ab1abeac2
#5 resolve docker.io/library/nginx:alpine@sha256:df221db836e1754089190208cee7eeda94f233197056426eda74a43ab1abeac2 0.0s done
#5 DONE 0.1s

#6 [2/2] COPY index.html /usr/share/nginx/html/index.html
#6 DONE 0.0s

#7 exporting to image
#7 exporting layers 0.1s done
#7 exporting manifest sha256:61b84ea2aea2d60872a34a48754d88513f482fa6743b168b6e50124ee7d25bcc done
#7 exporting config sha256:78d86b451b401577ebad7ee818aafd87299656745ceb383aa0a243a2fe5b5c5f done
#7 exporting attestation manifest sha256:9e5697a8e065232f50a6c22b59ed2c9cf77e1897e7a7cf2f749bd9d455eebf2b 0.0s done
#7 exporting manifest list sha256:ad5a652f44531ea767c59623587172de8127c41536e38abcd13f01fcb00f4d59 done
#7 naming to docker.io/library/monsite:1.0
#7 naming to docker.io/library/monsite:1.0 done
#7 unpacking to docker.io/library/monsite:1.0 0.0s done
#7 DONE 0.2s
```

On voit les deux étapes du Dockerfile : `[1/2] FROM` et `[2/2] COPY`. Le `.` à la fin de la commande indique le dossier à envoyer à Docker pour le build (c'est là que `COPY` va chercher `index.html`).

```text
> docker images monsite
REPOSITORY   TAG   IMAGE ID       SIZE
monsite      1.0   ad5a652f4453   93.6MB

> docker history monsite:1.0
CREATED BY                                      SIZE
COPY index.html /usr/share/nginx/html/index.…   24.6kB
RUN /bin/sh -c set -x && apkArch="$(cat …       52.4MB
...
```

Avec `docker history`, on voit que mon image, c'est l'image nginx:alpine plus une couche de quelques Ko pour mon fichier HTML. Les couches de nginx ne sont pas recopiées, elles sont réutilisées.

---

## 7. Lancer un conteneur avec mon image

```text
> docker run --name monsite1 -p 8081:80 -d monsite:1.0
af37509e87851d2359bfbe57ff5e1f2baedbd3a50bafa7a9e6582e2984673abf

> docker ps --filter name=monsite1
CONTAINER ID   IMAGE         COMMAND                  CREATED         STATUS         PORTS                                     NAMES
af37509e8785   monsite:1.0   "/docker-entrypoint.…"   3 seconds ago   Up 2 seconds   0.0.0.0:8081->80/tcp, [::]:8081->80/tcp   monsite1
```

Sur `http://localhost:8081` j'ai bien ma page "Hello depuis mon image Docker".

```text
> docker logs monsite1
...
172.17.0.1 - - [05/Oct/2026:08:38:53 +0000] "GET / HTTP/1.1" 200 207 "-" "Mozilla/5.0 ..."
```

On voit ma requête dans les logs nginx. Elle vient de `172.17.0.1`, l'adresse de la passerelle du réseau Docker.

Petit problème rencontré : en testant la page avec `Invoke-WebRequest` dans PowerShell, le "é" de "Buildé" s'affichait "Ã©". Dans le navigateur c'est correct. C'est PowerShell qui décode mal la page parce que nginx n'indique pas l'encodage dans sa réponse.

```text
> docker stop monsite1
> docker rm monsite1
```

---

## 8. Publication de l'image

### Test avec un registre local

Avant de passer à Docker Hub, j'ai d'abord testé le push et le pull en local. Pour ça, j'ai lancé un registre Docker en local avec l'image `registry:2`. Il fonctionne comme Docker Hub, mais sur ma machine (port 5000).

```text
> docker run -d -p 5000:5000 --name registry registry:2

> docker tag monsite:1.0 localhost:5000/monsite:1.0
> docker tag monsite:1.0 localhost:5000/monsite:latest

> docker push localhost:5000/monsite:1.0
The push refers to repository [localhost:5000/monsite]
f505aee1e20f: Pushed
745dfb2690dd: Pushed
d9aae54b5831: Pushed
93e0c0b595e9: Pushed
64c8194480fe: Pushed
9a9a644fdd6a: Pushed
e76228b47809: Pushed
6c53d0b2a666: Pushed
e2de96513ba9: Pushed
e72112c14215: Pushed
1.0: digest: sha256:ad5a652f44531ea767c59623587172de8127c41536e38abcd13f01fcb00f4d59 size: 856

> docker push localhost:5000/monsite:latest
64c8194480fe: Layer already exists
...
latest: digest: sha256:ad5a652f...
```

Pour le deuxième push (`latest`), toutes les couches étaient déjà sur le registre ("Layer already exists"), et le digest est le même. Les deux tags pointent donc vers la même image.

Ensuite j'ai supprimé l'image en local et je l'ai récupérée depuis le registre :

```text
> docker rmi localhost:5000/monsite:1.0 localhost:5000/monsite:latest
Untagged: localhost:5000/monsite:1.0
Untagged: localhost:5000/monsite:latest

> docker pull localhost:5000/monsite:1.0
Digest: sha256:ad5a652f44531ea767c59623587172de8127c41536e38abcd13f01fcb00f4d59
Status: Downloaded newer image for localhost:5000/monsite:1.0

> docker run --name monsite2 -p 8082:80 -d localhost:5000/monsite:1.0
```

Sur `http://localhost:8082` j'ai bien ma page. Le digest est le même qu'au moment du push, donc c'est exactement la même image.

### Sur Docker Hub

Ensuite j'ai lancé `docker login` pour me connecter à Docker Hub. C'est la même démarche que pour le registre local, mais à la place de `localhost:5000` on met son nom d'utilisateur Docker Hub (pour moi `moiseal`). Ce n'est ni l'adresse mail ni le code reçu pendant le `docker login`.

#### Tag

```text
PS C:\Users\Leclerc> docker tag monsite:1.0 moiseal/monsite:1.0
PS C:\Users\Leclerc> docker tag monsite:1.0 <mon_identifiant>/monsite:latest
Au caractère Ligne:1 : 24
+ docker tag monsite:1.0 <mon_identifiant>/monsite:latest
+                        ~
L'opérateur « < » est réservé à une utilisation future.
    + CategoryInfo          : ParserError: (:) [], ParentContainsErrorRecordException
    + FullyQualifiedErrorId : RedirectionNotSupported

PS C:\Users\Leclerc> docker tag monsite:1.0 moiseal/monsite:latest
```

Erreur de ma part : j'avais copié la commande avec `<mon_identifiant>` sans le remplacer. PowerShell interprète `<` comme un opérateur de redirection, d'où l'erreur. La commande n'a même pas été envoyée à Docker. Après avoir remis `moiseal`, le tag a fonctionné (`docker tag` n'affiche rien quand tout va bien).

#### Push

```text
PS C:\Users\Leclerc> docker push moiseal/monsite:1.0
The push refers to repository [docker.io/moiseal/monsite]
93e0c0b595e9: Pushed
6c53d0b2a666: Mounted from library/nginx
64c8194480fe: Mounted from library/nginx
e72112c14215: Mounted from library/nginx
745dfb2690dd: Mounted from library/nginx
e76228b47809: Mounted from library/nginx
f505aee1e20f: Pushed
e2de96513ba9: Mounted from library/nginx
d9aae54b5831: Mounted from library/nginx
9a9a644fdd6a: Mounted from library/nginx
1.0: digest: sha256:ad5a652f44531ea767c59623587172de8127c41536e38abcd13f01fcb00f4d59 size: 856

PS C:\Users\Leclerc> docker push moiseal/monsite:latest
The push refers to repository [docker.io/moiseal/monsite]
9a9a644fdd6a: Layer already exists
e2de96513ba9: Layer already exists
f505aee1e20f: Already exists
93e0c0b595e9: Layer already exists
6c53d0b2a666: Layer already exists
64c8194480fe: Layer already exists
e76228b47809: Layer already exists
745dfb2690dd: Layer already exists
e72112c14215: Layer already exists
d9aae54b5831: Layer already exists
latest: digest: sha256:ad5a652f44531ea767c59623587172de8127c41536e38abcd13f01fcb00f4d59 size: 856
```

Ce que j'ai remarqué dans ces logs :
- On voit `docker.io/moiseal/monsite` : grâce au tag, Docker a compris qu'il fallait envoyer l'image sur Docker Hub, dans mon compte.
- Seules 2 couches ont réellement été envoyées (`Pushed`). Les 8 autres sont marquées `Mounted from library/nginx` : ce sont les couches de l'image nginx officielle, qui sont déjà sur Docker Hub. Docker Hub les réutilise au lieu de me les faire envoyer à nouveau, c'est pour ça que le push a été très rapide.
- Pour `latest`, rien n'a été renvoyé (`Layer already exists`) et le digest est le même que pour `1.0` : ce sont deux noms pour la même image.
- Le digest `sha256:ad5a65…` est aussi le même que lors du test avec le registre local. C'est bien exactement la même image partout.

L'image est maintenant visible sur https://hub.docker.com/r/moiseal/monsite.

#### Vérification

Pour vérifier que l'image peut être récupérée depuis Docker Hub, j'ai supprimé le conteneur `monsite2` et les tags locaux, puis j'ai fait un pull et relancé un conteneur :

```text
PS C:\Users\Leclerc> docker rm -f monsite2
monsite2
PS C:\Users\Leclerc> docker rmi moiseal/monsite:1.0 moiseal/monsite:latest monsite:1.0
Untagged: moiseal/monsite:1.0
Untagged: moiseal/monsite:latest
Untagged: monsite:1.0
PS C:\Users\Leclerc> docker pull moiseal/monsite:1.0
1.0: Pulling from moiseal/monsite
Digest: sha256:ad5a652f44531ea767c59623587172de8127c41536e38abcd13f01fcb00f4d59
Status: Downloaded newer image for moiseal/monsite:1.0
docker.io/moiseal/monsite:1.0
PS C:\Users\Leclerc> docker run --name monsite2 -p 8082:80 -d moiseal/monsite:1.0
dd2987e43960a1ed2b8a2fa042c18f8f2b29e40dad9e33f5d8cb227bd077f611
```

Le conteneur tourne et `http://localhost:8082` affiche bien "Hello depuis mon image Docker". Le digest renvoyé par Docker Hub est le même que celui du push.

En relisant la sortie, j'ai remarqué que `docker rmi` n'affiche que des lignes `Untagged` et aucune ligne `Deleted`. L'image n'a donc pas été supprimée de mon PC : il lui restait un autre nom, `localhost:5000/monsite:1.0`, qui datait du test avec le registre local. Docker ne supprime une image que quand plus aucun tag ne pointe dessus. Du coup, au moment du pull, Docker Hub a confirmé que c'était la bonne image (même digest), mais aucune couche n'a eu besoin d'être retéléchargée.

J'ai donc refait le test en supprimant aussi ce tag :

```text
PS C:\Users\Leclerc> docker rm -f monsite2
monsite2
PS C:\Users\Leclerc> docker rmi moiseal/monsite:1.0 localhost:5000/monsite:1.0
Untagged: moiseal/monsite:1.0
Untagged: localhost:5000/monsite:1.0
Deleted: sha256:ad5a652f44531ea767c59623587172de8127c41536e38abcd13f01fcb00f4d59
PS C:\Users\Leclerc> docker pull moiseal/monsite:1.0
1.0: Pulling from moiseal/monsite
93e0c0b595e9: Pull complete
Digest: sha256:ad5a652f44531ea767c59623587172de8127c41536e38abcd13f01fcb00f4d59
Status: Downloaded newer image for moiseal/monsite:1.0
docker.io/moiseal/monsite:1.0
PS C:\Users\Leclerc> docker run --name monsite2 -p 8082:80 -d moiseal/monsite:1.0
ac71e443ea4a45c195da69869d054b1bf434657aedb4a19d544466bc5803aee3
```

Cette fois il y a bien une ligne `Deleted` : plus aucun tag ne pointait sur l'image, Docker l'a supprimée.

Au pull, une seule couche a été téléchargée : `93e0c0b595e9`. C'est la couche qui contient mon `index.html` (celle qui était `Pushed` et non `Mounted from library/nginx` lors du push). Les autres couches n'ont pas été retéléchargées parce qu'elles sont toujours sur mon PC dans l'image `nginx:alpine`. Docker partage les couches entre les images et ne télécharge que ce qui manque. Sur une machine qui n'aurait jamais téléchargé nginx, toutes les couches seraient téléchargées.

Le conteneur a redémarré avec l'image venant de Docker Hub, et la page s'affiche toujours sur `http://localhost:8082`. Le cycle complet build → tag → push → pull → run fonctionne.

---

## 9. Réponses aux questions

### 1. Quelle différence entre image et conteneur ?

L'image est un modèle en lecture seule. Elle contient tout ce qu'il faut pour lancer l'application (système de base, fichiers, configuration, commande de démarrage), mais elle ne s'exécute pas elle-même.

Le conteneur est une instance de cette image en train de tourner (ou arrêtée). Docker ajoute par-dessus l'image une couche où le conteneur peut écrire, et lance le processus de façon isolée du reste de la machine.

On peut comparer ça à une classe et un objet en programmation : une seule image peut servir à lancer plusieurs conteneurs. Dans le TP, `monsite:1.0` a servi pour `monsite1` puis `monsite2`.

Le TP le montre bien avec MySQL : quand j'ai supprimé le conteneur, l'image était toujours là. Les données, elles, n'ont survécu que parce qu'elles étaient dans un volume. Sans volume, elles auraient été dans la couche du conteneur et auraient été perdues.

### 2. À quoi sert -p 8081:80 ? Dans quel sens va le mapping ?

`-p` sert à publier un port du conteneur sur ma machine. Le format est `-p port_hôte:port_conteneur`.

Avec `-p 8081:80`, tout ce qui arrive sur le port 8081 de mon PC est redirigé vers le port 80 du conteneur, où nginx écoute. Le sens est donc hôte → conteneur. C'est pour ça qu'on ouvre `http://localhost:8081` et pas le port 80.

Sans `-p`, le site tournerait quand même dans le conteneur, mais je ne pourrais pas y accéder depuis mon navigateur.

Un port de l'hôte ne peut être utilisé que par un seul conteneur à la fois. C'est pour ça que j'ai dû mettre `3307:3306` pour `mysql2`. Par contre, plusieurs conteneurs peuvent tous utiliser le même port à l'intérieur (80, 3306…).

### 3. Différence entre docker run et docker start ?

- `docker run` crée un nouveau conteneur à partir d'une image, puis le démarre. C'est là qu'on donne les options (`-p`, `-v`, `-e`, `--name`…). Si l'image n'est pas en local, il la télécharge d'abord.
- `docker start` redémarre un conteneur qui existe déjà et qui a été arrêté. Il reprend la configuration choisie au moment du `run`, et les fichiers modifiés dans le conteneur sont toujours là.

Par exemple, si on refait `docker run --name web1 ...` alors que `web1` existe déjà (même arrêté), on obtient une erreur parce que le nom est déjà pris. Il faut utiliser `docker start web1`. Et pour changer un port ou une variable, on ne peut pas passer par `start` : il faut supprimer le conteneur et refaire un `run`.

### 4. Quelle commande donne la configuration complète d'un conteneur ?

```bash
docker inspect web1
```

Elle affiche toute la configuration au format JSON : image utilisée, commande lancée, variables d'environnement, ports, volumes, adresse IP, état…

On peut filtrer avec `-f` pour n'avoir qu'une information, par exemple l'IP :

```bash
docker inspect -f '{{.NetworkSettings.IPAddress}}' web1
```

### 5. Pourquoi tagger une image avant un docker push ?

Parce que c'est le nom de l'image qui dit à Docker où l'envoyer. Mon image s'appelle `monsite:1.0`, et pour Docker ça veut dire `docker.io/library/monsite:1.0`. `library` est réservé aux images officielles de Docker Hub, je n'ai pas le droit d'y publier.

En faisant `docker tag monsite:1.0 moiseal/monsite:1.0`, je donne un deuxième nom à la même image (ça ne la copie pas). Ce nom contient mon compte Docker Hub, donc Docker sait dans quel dépôt la pousser : dans les logs du push on voit bien `docker.io/moiseal/monsite`. Pour le registre local, c'était pareil avec `localhost:5000/monsite`.

Le tag sert aussi à gérer les versions : `1.0` désigne une version précise, et `latest` désigne la dernière version. Dans le TP, les deux tags pointaient vers la même image (même digest).

---

## Ce que je retiens

- Une image se construit avec un Dockerfile, et chaque instruction ajoute une couche.
- Un conteneur est jetable : tout ce qui doit être gardé doit aller dans un volume.
- Un conteneur partage le noyau de la machine hôte, ce n'est pas une VM.
- `docker inspect`, `docker logs` et `docker exec` sont les commandes les plus utiles pour comprendre ce qui se passe dans un conteneur.
- Pour publier une image, il faut d'abord la tagger avec le nom du registre et du compte.
