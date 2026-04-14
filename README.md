# URL Watcher avec GitHub Actions

Ce projet surveille une page web toutes les 5 minutes avec GitHub Actions.
Si le nombre de messages, le nombre de caracteres ou le contenu utile change, un e-mail est envoye.

La logique metier reste en PowerShell.
GitHub Actions ne fait que lancer le script, conserver `state/state.json` et pousser la mise a jour du fichier d'etat.

## Architecture tres simple

1. GitHub Actions lance `watch-url.ps1` toutes les 5 minutes.
2. Le script telecharge la page, extrait le contenu utile et calcule les mesures.
3. Le script compare avec `state/state.json`.
4. Si rien ne change, aucun e-mail n'est envoye.
5. Si quelque chose change, un e-mail est envoye.
6. Le workflow commit automatiquement `state/state.json` uniquement s'il a vraiment change.

## Arborescence

```text
url_watcher/
|-- .github/
|   `-- workflows/
|       `-- url-watcher.yml
|-- state/
|   |-- state.json
|   `-- thread-state.json
|-- .gitignore
|-- config.github-actions.json
|-- config.sample.json
|-- config.thread.json
|-- README.md
|-- start-watcher.bat
|-- test-email.bat
|-- test-watcher.bat
`-- watch-url.ps1
```

Notes :
- `watch-url.ps1` est le script principal.
- `config.github-actions.json` est la configuration utilisee par GitHub Actions.
- `state/state.json` est le seul fichier d'etat a committer.
- `config.thread.json` reste local et est ignore par `.gitignore`.

## Pourquoi cette solution est fiable

- Pas de base externe.
- Pas de Docker.
- Pas de dependance a installer.
- Le runner GitHub sait deja executer `pwsh`.
- Le fichier `state/state.json` suffit pour memoriser l'etat precedent.
- Le workflow ne tourne pas sur `push`, donc le commit du state ne cree pas de boucle infinie.
- Une erreur HTTP est retentee automatiquement 3 fois.
- Le premier lancement cree une baseline sans envoyer d'e-mail.
- Les erreurs identiques ne renvoient pas un e-mail a chaque run.

## Strategie anti faux positifs

Le script ne compare pas le HTML complet de la page.
Il extrait seulement le texte utile des vrais messages XenForo, puis :

- il ignore le bruit HTML
- il normalise les espaces
- il compare le nombre de messages
- il compare le nombre de caracteres
- il compare aussi un hash du contenu utile

Cela evite la plupart des faux positifs lies aux reactions, au markup ou aux variations mineures de mise en page.

## Installation ultra detaillee sur GitHub

### 1. Creer le depot

1. Va sur GitHub.
2. Clique sur `New repository`.
3. Donne un nom, par exemple `url-watcher`.
4. Cree le depot.

### 2. Mettre les fichiers dans le depot

Place dans ton depot les fichiers de ce dossier :

- `.github/workflows/url-watcher.yml`
- `watch-url.ps1`
- `config.github-actions.json`
- `state/state.json`
- `.gitignore`
- `README.md`

Tu peux aussi garder les autres fichiers locaux, mais ils ne sont pas necessaires pour GitHub Actions.

### 3. Envoyer le code sur GitHub

Si tu utilises GitHub Desktop :

1. Ouvre le dossier comme depot Git.
2. Verifie que `config.thread.json` n'apparait pas dans les fichiers a committer.
3. Commit.
4. Push vers GitHub.

Si tu utilises l'interface web GitHub :

1. Ouvre le depot.
2. Clique sur `Add file`.
3. Ajoute les fichiers un par un.
4. Commit sur la branche principale.

### 4. Ajouter les secrets

Dans GitHub :

1. Ouvre ton depot.
2. Clique sur `Settings`.
3. Clique sur `Secrets and variables`.
4. Clique sur `Actions`.
5. Clique sur `New repository secret`.
6. Cree les secrets de la liste plus bas.

### 5. Activer les permissions d'ecriture du workflow

En general, le workflow fonctionnera directement avec :

- `permissions: contents: write`

Si GitHub refuse le push du state :

1. Va dans `Settings`.
2. Clique sur `Actions`.
3. Clique sur `General`.
4. Cherche `Workflow permissions`.
5. Coche `Read and write permissions`.
6. Sauvegarde.

### 6. Lancer le premier run

1. Va dans l'onglet `Actions`.
2. Ouvre le workflow `URL Watcher`.
3. Clique sur `Run workflow`.
4. Laisse `send_test_email` sur `false`.
5. Lance le workflow.

Le premier run ne doit pas envoyer d'e-mail de changement.
Il doit seulement creer une baseline dans `state/state.json`.

## Secrets a creer

Cree exactement ces secrets dans GitHub :

- `URL_WATCH_URL`
  Le lien complet Leakimedia a surveiller.

- `URL_WATCH_SMTP_USERNAME`
  Ton identifiant SMTP.
  Si tu utilises Gmail, c'est souvent ton adresse Gmail.

- `URL_WATCH_SMTP_PASSWORD`
  Ton mot de passe SMTP ou ton app password.

- `URL_WATCH_SMTP_FROM`
  L'adresse expeditrice.

- `URL_WATCH_SMTP_TO`
  Les destinataires, separes par des virgules.
  Exemple :
  `dest1@example.com,dest2@example.com`

Important :
- ne mets jamais ces valeurs dans le code
- ne commit jamais un fichier contenant l'URL ou les adresses e-mail

## Test manuel

### Test 1 : verifier que le workflow demarre

1. Va dans `Actions`.
2. Ouvre `URL Watcher`.
3. Clique sur `Run workflow`.
4. Lance avec `send_test_email = false`.

Resultat attendu :
- le job demarre
- le script affiche des logs lisibles
- `state/state.json` est eventuellement mis a jour
- un commit automatique peut apparaitre si le state a change

### Test 2 : verifier l'envoi SMTP

1. Va dans `Actions`.
2. Lance `Run workflow`.
3. Mets `send_test_email = true`.
4. Lance le workflow.

Resultat attendu :
- tu recois un e-mail de test
- le job finit en succes

### Test 3 : verifier la persistance

1. Lance une premiere fois le workflow avec `send_test_email = false`.
2. Verifie que `state/state.json` a ete committe.
3. Relance le workflow une seconde fois.

Resultat attendu :
- si la page n'a pas change, aucun e-mail de changement n'est envoye
- le state reste stable ou se met seulement a jour sur les dates utiles

## Que contient state/state.json

Le fichier d'etat stocke seulement des metadonnees non sensibles :

- dernier statut
- date de creation de la baseline
- hash du contenu utile
- nombre de caracteres
- nombre de messages
- derniere page detectee
- horodatage du dernier changement
- empreinte de la derniere erreur

Il ne stocke pas l'URL, les destinataires ni les identifiants SMTP.

## Logs GitHub Actions

Les logs affichent notamment :

- les tentatives HTTP
- les mesures extraites
- baseline ou pas
- changement detecte ou non
- e-mail envoye ou non
- sauvegarde du state

## Depannage

### Le workflow ne se lance pas

Verifie :

- que le fichier est bien dans `.github/workflows/url-watcher.yml`
- que le depot est sur GitHub
- que GitHub Actions est autorise pour le depot
- que tu regardes bien la bonne branche

### Le workflow planifie toutes les 5 minutes mais ne tombe pas exactement a la minute

C'est normal.
GitHub Actions peut avoir un leger retard sur les jobs planifies.
Le cron reste bien configure toutes les 5 minutes.

### Le workflow echoue sur le push du state

Cause probable :
- permissions d'ecriture non actives pour `GITHUB_TOKEN`

Solution :
- active `Read and write permissions` dans les reglages Actions du depot

### Le workflow echoue avec une erreur HTTP

Le script gere deja :

- timeout HTTP
- contenu vide
- 3 tentatives avec pause

Si l'erreur continue :

- verifie que l'URL est correcte dans `URL_WATCH_URL`
- verifie que le site n'a pas change de structure
- verifie qu'il ne bloque pas temporairement les requetes automatiques

### Le mail ne part pas

Verifie :

- `URL_WATCH_SMTP_USERNAME`
- `URL_WATCH_SMTP_PASSWORD`
- `URL_WATCH_SMTP_FROM`
- `URL_WATCH_SMTP_TO`
- le port SMTP dans `config.github-actions.json`
- que le fournisseur SMTP accepte l'envoi depuis GitHub Actions

Pour Gmail :

- utilise de preference un app password
- l'authentification classique peut etre refusee

### Aucun e-mail n'est envoye alors que tu attends une alerte

Verifie :

- que le contenu utile a vraiment change
- que le changement n'est pas seulement cosmetique
- que `state/state.json` n'a pas ete supprime entre deux runs

### Tu recois trop d'e-mails

Verifie :

- si le site change souvent de structure
- si les messages extraits contiennent du bruit nouveau
- si le forum ajoute des variations non prevues

Dans ce cas, il faudra ajuster l'extraction du contenu, pas l'infrastructure GitHub Actions.

## Fichiers importants

- `watch-url.ps1`
  Script principal.

- `config.github-actions.json`
  Configuration GitHub Actions sans secret en dur.

- `.github/workflows/url-watcher.yml`
  Workflow planifie et manuel.

- `state/state.json`
  Memoire persistante entre deux runs.

## Utilisation locale possible

Le script reste compatible en local.
Tu peux encore utiliser un fichier de config local contenant `url`, `smtp.from`, `smtp.to`, etc.

Pour GitHub Actions, les secrets passent par les variables d'environnement.
