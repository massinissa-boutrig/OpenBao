# RUNBOOK — OpenBao HA mono-DC sur OpenStack

> Procédures d'exploitation à destination des opérateurs habilités. Toutes les commandes `bao` supposent que l'environnement `BAO_ADDR=https://127.0.0.1:8200` et `BAO_CACERT=/etc/openbao/tls/ca.crt` est positionné (cf. `/etc/default/openbao`). Le binaire OpenBao est en `/usr/bin/bao` (paquet .deb officiel).

---

## Sommaire

0. [Prérequis OpenStack](#0-prérequis-openstack)
1. [Initialisation du cluster](#1-initialisation-du-cluster)
2. [Unseal après reboot](#2-unseal-après-reboot)
3. [Snapshot Raft](#3-snapshot-raft)
4. [Restore depuis snapshot](#4-restore-depuis-snapshot)
5. [Rotation des certificats TLS](#5-rotation-des-certificats-tls)
6. [Ajout d'un nœud](#6-ajout-dun-nœud)
7. [Retrait d'un nœud](#7-retrait-dun-nœud)
8. [Dépannage](#8-dépannage)

---

## 0. Prérequis OpenStack

> **À lire avant tout déploiement.** Ce projet Ansible configure uniquement l'OS et les services — la création des VMs, des security groups, de la Floating IP et du compte Keystone dédié doit être faite en amont (Terraform, Heat, openstack CLI, ou console Horizon). Les éléments ci-dessous sont **indispensables** au bon fonctionnement de la HA.

### 0.1 ServerGroup anti-affinity (3 AZ)

Les 3 nœuds OpenBao doivent être répartis sur **3 Availability Zones distinctes** pour tolérer la perte d'une AZ. On utilise un `ServerGroup` avec la policy `anti-affinity`, qui garantit en plus que Nova ne place pas deux VMs du groupe sur le même hyperviseur.

```bash
# Création du ServerGroup (une seule fois)
openstack server group create --policy anti-affinity openbao-cluster
# → noter l'ID retourné, à passer en --hint group=<id> à chaque `openstack server create`

# Provisioning des 3 VMs, une par AZ
for i in 1 2 3; do
  openstack server create \
    --flavor m1.medium \
    --image debian-13-trixie \
    --availability-zone az-$i \
    --hint group=<server_group_id> \
    --security-group openbao-nodes \
    --key-name ops \
    --network openbao-net \
    bao-node-$i
done
```

Les 2 HAProxy peuvent être dans 2 AZ différentes (idéalement az-1 et az-2) sans ServerGroup strict.

### 0.2 Security groups

| Security group | Ingress | Source | Justification |
|---|---|---|---|
| `openbao-nodes` | TCP 22 | bastion | SSH admin |
| `openbao-nodes` | TCP 8200 | `haproxy-frontends` | API OpenBao |
| `openbao-nodes` | TCP 8201 | `openbao-nodes` | Réplication Raft (mTLS) |
| `haproxy-frontends` | TCP 22 | bastion | SSH admin |
| `haproxy-frontends` | TCP 8200 | subnet clients | Frontend Floating IP |
| `haproxy-frontends` | TCP 8404 | subnet supervision | Page stats HAProxy |

Plus aucune règle VRRP / protocole 112 : la bascule frontale est portée par l'API Neutron, pas par VRRP. L'egress doit autoriser HTTPS (443) sortant vers les endpoints Keystone et Neutron depuis `haproxy-frontends`. nftables applique un second filtre local plus strict (policy drop).

### 0.3 Floating IP Neutron préallouée

L'architecture utilise une **Floating IP OpenStack** réattachée entre les deux HAProxy via appel API Neutron (plus de VRRP, plus d'`allowed-address-pairs`). Il faut donc préallouer cette FIP sur un réseau externe et récupérer son UUID pour l'injecter dans `openstack_floating_ip_id` (vault).

```bash
# Création de la FIP (une seule fois)
openstack floating ip create public --description "OpenBao HA frontend" -f value -c floating_ip_address -c id
# → retenir l'adresse (ex : 10.10.0.100) ET l'UUID

# L'attacher initialement au port de ha-1 pour démarrer sur le master
PORT_HA1=$(openstack port list --server ha-1 -f value -c ID)
openstack floating ip set --port $PORT_HA1 <fip_uuid>
```

Renseigner ensuite `openstack_floating_ip: 10.10.0.100` dans `hosts.yml` et `openstack_floating_ip_id: <uuid>` dans le vault. Le script `openbao-fip-failover.py` (rôle `openstack_fip`) prend ensuite le relais.

### 0.6 Compte Keystone restreint pour le failover de FIP

Le rôle `openstack_fip` déploie un script qui appelle Neutron pour réattacher la Floating IP. Ce compte doit avoir **le strict minimum de privilèges** : `update_floatingip` + `get_floatingip` sur la FIP cible et `get_port` sur les ports HAProxy. Rien de plus.

```bash
# Rôle Keystone dédié (à créer une fois)
openstack role create openbao-fip-failover
openstack user create --project <project> --password <mdp> openbao-fip-failover
openstack role add --project <project> --user openbao-fip-failover openbao-fip-failover
```

Merger dans `/etc/neutron/policy.yaml` :

```yaml
"role:openbao-fip-failover and project_id:%(project_id)s":
  - get_floatingip
  - update_floatingip
  - get_port
```

Vérification : depuis ha-1, `sudo -u openbao-fip ... floating ip show <uuid>` doit réussir, `... server list` doit échouer (Forbidden) — preuve que le compte est bien contraint. Rotation du mot de passe : tous les 6 mois minimum, via `openstack user set --password` puis replay du rôle.

### 0.4 Flavor et stockage recommandés

| Composant | vCPU | RAM | Disque | Volume Cinder |
|---|---|---|---|---|
| OpenBao | 2 | 4 Go | 20 Go (racine) | 20 Go ext4 pour `/var/lib/openbao` (Raft) |
| HAProxy | 1 | 2 Go | 10 Go (racine) | — |

Le volume Cinder sur les OpenBao est recommandé pour : (a) découpler le stockage Raft du disque racine, (b) permettre un snapshot Cinder à froid avant opération sensible, (c) faciliter la reprise sur défaillance d'hyperviseur (re-attach rapide).

### 0.5 Cloud-init minimal

Image de base : Debian 13 (Trixie) officielle. Cloud-init doit au minimum :
- Créer l'utilisateur `ansible` (ou équivalent) avec la clé publique du contrôleur.
- Injecter `/etc/hosts` si le DNS interne n'est pas disponible avant Ansible.
- Activer `qemu-guest-agent` (utile pour les snapshots Cinder cohérents).

Ne **pas** activer `unattended-upgrades` sur les OpenBao : les mises à jour du paquet `bao` doivent rester manuelles et contrôlées (elles impliquent un unseal).

---

## 1. Initialisation du cluster

> **À FAIRE UNE SEULE FOIS, à la mise en service initiale.** Ne jamais réinitialiser un cluster en production sans procédure de DR validée.

### 1.1 Préparation

Cinq opérateurs doivent être présents physiquement (ou en visio sécurisée) avec chacun leur coffre offline (KeePass, YubiKey, etc.) prêt à recevoir une clé. Le terminal de `bao-node-1` doit être partagé en lecture seule pendant la cérémonie pour que les cinq personnes constatent la génération.

### 1.2 Exécution sur bao-node-1

```bash
ssh bao-node-1
sudo -iu openbao

# Génération des 5 parts Shamir, seuil de 3
bao operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/init.json
chmod 600 /tmp/init.json

# Affichage à l'écran (capture interdite)
cat /tmp/init.json
```

Le fichier contient cinq `unseal_keys_b64` et un `root_token`. **Distribuer immédiatement** :

| Destinataire | Élément | Stockage |
|---|---|---|
| Opérateur 1 | `unseal_keys_b64[0]` | KeePass perso |
| Opérateur 2 | `unseal_keys_b64[1]` | KeePass perso |
| Opérateur 3 | `unseal_keys_b64[2]` | KeePass perso |
| Opérateur 4 | `unseal_keys_b64[3]` | KeePass perso |
| Opérateur 5 | `unseal_keys_b64[4]` | KeePass perso |
| Lead exploitation | `root_token` | KeePass perso (à révoquer dès qu'une AppRole admin est créée) |

Une fois la distribution confirmée par chaque opérateur (lecture inverse pour vérification) :

```bash
shred -u /tmp/init.json
history -c
```

### 1.3 Unseal initial des trois nœuds

Sur **bao-node-1** (puis répéter sur node-2 et node-3) :

```bash
bao operator unseal   # opérateur 1 saisit sa clé
bao operator unseal   # opérateur 2 saisit sa clé
bao operator unseal   # opérateur 3 saisit sa clé
```

À chaque fois, vérifier `Sealed: false`.

### 1.4 Vérification du cluster

```bash
bao login <root_token>
bao operator raft list-peers
```

Le résultat attendu :

```
Node     Address              State      Voter
----     -------              -----      -----
node-1   10.10.1.10:8201      leader     true
node-2   10.10.2.10:8201      follower   true
node-3   10.10.3.10:8201      follower   true
```

### 1.5 Activation de l'audit log

```bash
bao audit enable file file_path=/var/log/openbao/audit.log
```

À ce stade, le cluster est opérationnel.

---

## 1bis. Configuration auth + secrets + policies (déclaratif)

> **Une fois le cluster initialisé et unsealed**, le rôle `openbao` peut configurer lui-même les méthodes d'authentification (userpass, AppRole), les secret engines (KV v2 par projet) et les policies RBAC (admin, auditor, secrets-rw/ro par projet). C'est entièrement piloté par l'inventaire et idempotent.

### 1bis.1 Pré-requis

- Cluster initialisé et unsealed (cf. §1).
- Le fichier `inventories/production/group_vars/all/init.vault.yml` existe (généré par l'auto-init) et contient `openbao_root_token`. Sinon, fournir le token via `vault.yml` ou `--extra-vars`.
- Inventaire renseigné : `openbao_projects`, `openbao_userpass_users`, `openbao_approles` dans `group_vars/all/main.yml` ; mots de passe userpass dans `vault.yml` chiffré.

### 1bis.2 Lancer la configuration

Deux options équivalentes :

```bash
# Option A : playbook autonome
ansible-playbook playbooks/configure.yml --ask-vault-pass

# Option B : activer dans site.yml
ansible-playbook playbooks/site.yml \
  -e openbao_auto_configure_enabled=true --ask-vault-pass
```

À l'issue, le résumé en sortie liste les méthodes d'auth, les mounts KV, les users et les AppRoles configurés. Les policies déployées sont :

| Policy | Capacités | Cible |
|---|---|---|
| `admin` | full sauf seal/init/snapshot-force | Opérateurs habilités |
| `auditor` | read-only sur health/audit/metrics/policies/mounts | Auditeurs internes/externes |
| `secrets-rw-<projet>` | CRUD sur `kv-<projet>/data/*` | CI/CD du projet |
| `secrets-ro-<projet>` | read sur `kv-<projet>/data/*` | Workloads consommateurs |

### 1bis.3 Ajouter un projet

1. Ajouter `{ name: nouveau-projet }` dans `openbao_projects` (group_vars).
2. Replay : `ansible-playbook playbooks/configure.yml --ask-vault-pass`.
3. Le mount `kv-nouveau-projet/` et les policies `secrets-rw-nouveau-projet` + `secrets-ro-nouveau-projet` sont créés.

### 1bis.4 Ajouter un utilisateur userpass

1. Choisir un nom de variable mot de passe (ex : `openbao_user_carol_password`).
2. L'ajouter dans `vault.yml` (chiffré) avec une valeur forte (16+ caractères).
3. Déclarer l'utilisateur dans `openbao_userpass_users` :

   ```yaml
   - name: carol
     password_var: openbao_user_carol_password
     policies: [secrets-ro-projet-a, secrets-ro-projet-b]
     token_ttl: 30m
   ```

4. Replay du playbook configure.

### 1bis.5 AppRole : générer un secret_id

La création de l'AppRole (role + policies + TTLs) est faite par `configure.yml`, mais la génération du `secret_id` est volontairement séparée pour utiliser le response wrapping (livraison one-shot, pas de stockage Ansible). Procédure manuelle en attendant le playbook dédié :

```bash
# Sur le nœud bootstrap, en tant qu'admin (token root ou admin)
bao login -method=token

# Générer un secret_id wrappé (ttl du wrap : 5 min)
bao write -wrap-ttl=5m -f auth/approle/role/<nom-approle>/secret-id
# → renvoie un wrap_token à transmettre IMMÉDIATEMENT au consommateur

# Le consommateur unwrap le secret_id (one-shot)
bao unwrap <wrap_token>
# → renvoie le secret_id réel + son ttl

# Récupérer le role_id (non sensible)
bao read auth/approle/role/<nom-approle>/role-id
```

Le consommateur s'authentifie ensuite avec :

```bash
bao write auth/approle/login role_id=<role_id> secret_id=<secret_id>
# → renvoie un token avec les policies de l'AppRole
```

### 1bis.6 Idempotence et drift

Le playbook configure est **additif par défaut** : il crée et met à jour, mais ne supprime jamais. Pour purger un user / AppRole / mount qui n'est plus déclaré dans l'inventaire, l'opération est manuelle (sécurité) :

```bash
bao delete auth/userpass/users/<nom>
bao delete auth/approle/role/<nom>
bao secrets disable kv-<ancien-projet>/
bao policy delete secrets-rw-<ancien-projet>
bao policy delete secrets-ro-<ancien-projet>
```

### 1bis.7 Audit log : vérification

Après le `configure`, deux audit devices sont actifs : `file/` (`/var/log/openbao/audit.log`) et `syslog/` (facility AUTH, tag openbao). Vérifier :

```bash
bao audit list
# Doit lister "file/" et "syslog/"

# Forcer une opération auditée pour test
bao kv list kv-projet-a/
tail -1 /var/log/openbao/audit.log | jq .
# → ligne JSON avec request.path, auth.entity_id, time, etc.

journalctl -t openbao --since "1 minute ago" | head
# → mêmes événements via syslog
```

Si le fichier audit reste vide alors que des opérations ont lieu : OpenBao bloque toutes les requêtes si AUCUN audit device n'est joignable (politique de sécurité). Vérifier les permissions `/var/log/openbao/` (owner openbao, mode 0750).

### 1bis.8 MFA TOTP : enrôlement utilisateur

> **À faire AVANT d'activer `openbao_mfa_enabled=true` en production.** Sinon les utilisateurs déjà créés ne pourront plus se connecter (login enforcement actif → exige TOTP, mais aucun user n'a de TOTP enrôlé).

Procédure d'enrôlement par utilisateur :

**Étape 1 — Activer le MFA en pré-prod ou avec 1 user pilote**

Dans `group_vars/all/main.yml` :
```yaml
openbao_mfa_enabled: true
```

Replay : `ansible-playbook playbooks/configure.yml --ask-vault-pass`.

**Étape 2 — Récupérer l'entity_id de l'utilisateur**

```bash
# Login admin (avant l'activation MFA, ou via root token)
bao login -method=token

# Trouver l'entity_id (créé automatiquement au 1er login userpass)
bao read -format=json identity/entity/name/<username> | jq -r .data.id
# → ex : 8d2a1c7f-3e91-4e5a-9b1c-1a2b3c4d5e6f
```

Si l'utilisateur n'a jamais loggé : créer l'entité manuellement :
```bash
bao write identity/entity name=<username> policies=secrets-rw-projet-a
ENTITY_ID=$(bao read -format=json identity/entity/name/<username> | jq -r .data.id)

# Lier l'entité à l'alias userpass (sinon les login userpass ne matchent pas)
USERPASS_ACCESSOR=$(bao auth list -format=json | jq -r '.["userpass/"].accessor')
bao write identity/entity-alias \
  name=<username> \
  canonical_id=$ENTITY_ID \
  mount_accessor=$USERPASS_ACCESSOR
```

**Étape 3 — Récupérer le method_id TOTP**

```bash
METHOD_ID=$(bao list -format=json identity/mfa/method/totp | jq -r '.[0]')
# → ex : a1b2c3d4-...
```

**Étape 4 — Générer le secret TOTP pour cet utilisateur**

```bash
bao write -force identity/mfa/method/totp/admin-generate \
  method_id=$METHOD_ID \
  entity_id=$ENTITY_ID
```

Sortie :
```
Key      Value
---      -----
barcode  iVBORw0KGgo...   # PNG base64 du QR code
url      otpauth://totp/OpenBao:<username>?secret=...&issuer=OpenBao
```

**Étape 5 — L'utilisateur scanne le QR code**

Décoder et afficher le QR :
```bash
bao write -format=json -force identity/mfa/method/totp/admin-generate \
  method_id=$METHOD_ID entity_id=$ENTITY_ID \
  | jq -r .data.barcode | base64 -d > /tmp/qr-<username>.png
# → transmettre /tmp/qr-<username>.png à l'utilisateur, qui le scanne avec
#   Google Authenticator / Authy / Yubico Authenticator / 1Password.
# → SUPPRIMER le fichier après confirmation : shred -u /tmp/qr-<username>.png
```

Alternative plus sécurisée — l'utilisateur scanne directement sur sa machine (avec port forward SSH) :
```bash
# Côté utilisateur, sur sa machine :
ssh -L 8200:127.0.0.1:8200 bao-node-1
# Puis dans son navigateur, ouvrir https://127.0.0.1:8200 → UI OpenBao,
# section "Multi-factor Authentication", suivre l'enrôlement guidé.
```

**Étape 6 — Tester le login avec TOTP**

```bash
# Sur n'importe quelle machine :
bao login -method=userpass username=<username>
# → demande le password (saisie classique)
# → demande ensuite le passcode TOTP (6 chiffres de l'authenticator)
```

Si OK : login réussi. Si échec : vérifier que la date système des nœuds OpenBao est synchronisée (NTP) — un décalage >30s casse le TOTP.

**Étape 7 — Activer en production**

Une fois TOUS les utilisateurs enrôlés et testés, déployer `openbao_mfa_enabled: true` sur l'inventaire prod et replay du configure.

> **Sortie de secours** : si un utilisateur perd son authenticator (téléphone cassé, vol), un admin peut effacer son enrôlement via `bao delete identity/mfa/method/totp/admin-destroy method_id=<id> entity_id=<id>`, puis réenrôler. Ne JAMAIS désactiver globalement le MFA pour résoudre ça.

### 1bis.9 Révocation du root token

> **À faire après le 1er run de configure**, dès que tout fonctionne. Le root token est all-powerful et n'expire jamais — sa simple existence est un risque permanent.

Procédure automatisée :

```bash
ansible-playbook playbooks/bootstrap-revoke-root.yml --ask-vault-pass
```

Le playbook :
1. Crée l'AppRole `admin-bootstrap` avec policy `admin` (full sauf seal/init).
2. Affiche le `role_id` + un `wrap_token` (ttl 5 min) — à conserver IMMÉDIATEMENT dans le KeePass du lead opérateur.
3. Demande confirmation interactive (l'opérateur doit avoir pu unwrap et se connecter avant de continuer).
4. Révoque le root token via `auth/token/revoke-self`.
5. Met à jour `init.vault.yml` pour retirer la variable `openbao_root_token`.

**Après révocation** : tous les playbooks qui utilisaient `openbao_root_token` doivent passer par l'AppRole `admin-bootstrap`. Login type :

```bash
# Sur le poste de l'opérateur, après unwrap initial
SECRET_ID=<obtenu via bao unwrap du wrap_token>
bao write -format=json auth/approle/login \
  role_id=<role_id_admin_bootstrap> \
  secret_id=$SECRET_ID \
  | jq -r .auth.client_token > ~/.openbao-admin-token

export VAULT_TOKEN=$(cat ~/.openbao-admin-token)
bao token lookup-self    # vérification
```

Pour rejouer `configure.yml` après révocation : passer le token admin en `--extra-vars openbao_root_token=$VAULT_TOKEN` (le nom de la variable reste mais son contenu est désormais un token AppRole, pas root).

---

## 2. Unseal après reboot

> **Tout reboot d'un nœud OpenBao le re-met en `sealed`.** C'est volontaire (Shamir manuel, pas d'auto-unseal).

### 2.1 Procédure standard

Pour chaque nœud à dé-sceller, mobiliser **trois** des cinq opérateurs :

```bash
ssh bao-node-X
sudo -iu openbao
bao status                 # confirmer Sealed: true
bao operator unseal        # opérateur A
bao operator unseal        # opérateur B
bao operator unseal        # opérateur C
bao status                 # confirmer Sealed: false, Initialized: true
```

### 2.2 Cas du redémarrage en chaîne

Si plusieurs nœuds sont à unseal, **les unseal en parallèle** (un terminal par nœud) — le quorum Raft se reforme automatiquement dès que deux nœuds sur trois sont unsealed.

### 2.3 Validation post-unseal

```bash
bao operator raft list-peers     # 3 voters
curl -k https://127.0.0.1:8200/v1/sys/health     # 200 ou 429 attendu
```

---

## 3. Snapshot Raft

### 3.1 Snapshot manuel

Depuis n'importe quel nœud unsealed, authentifié avec un token disposant de la policy `snapshot` :

```bash
bao operator raft snapshot save /var/backups/openbao/snapshot-$(date +%Y%m%d-%H%M%S).snap
```

Le snapshot contient l'état complet du cluster (KV, policies, auth methods, etc.) chiffré avec les clés Shamir.

### 3.2 Snapshot automatisé

Le playbook `playbooks/backup.yml` :

1. Détecte dynamiquement le leader Raft.
2. S'y connecte avec un token dédié (policy minimale, dans Ansible Vault).
3. Exécute le `snapshot save` dans `/var/backups/openbao/`.
4. Archive la copie vers le stockage externe paramétré (S3 ou NFS).

À planifier via systemd timer ou cron, recommandation : **toutes les 6 heures**.

### 3.3 Rétention

| Emplacement | Rétention |
|---|---|
| `/var/backups/openbao/` (local) | 30 jours |
| Stockage externe (S3/NFS) | 1 an |

Nettoyage local automatisé via le même playbook (`find -mtime +30 -delete`).

---

## 3bis. Sauvegarde des fichiers du contrôleur Ansible

> Le snapshot Raft (§3) couvre l'état d'OpenBao mais PAS les fichiers Ansible côté contrôleur. Si la machine du contrôleur est perdue (vol, panne, sinistre), on perd `init.vault.yml` (5 unseal keys + root token), `vault.yml` (passphrase CA + creds), et la PKI. **Aucun snapshot Raft ne peut être restauré sans ces fichiers**.

### 3bis.1 Procédure

```bash
# Préparer la passphrase GPG (une seule fois — KeePass perso, pas avec ansible-vault)
mkdir -p ~/.openbao && chmod 0700 ~/.openbao
echo 'passphrase_GPG_forte_32_chars_minimum' > ~/.openbao/backup.pass
chmod 0400 ~/.openbao/backup.pass

# Lancer la sauvegarde
ansible-playbook playbooks/backup-controller.yml

# Sortie : ~/openbao-controller-backups/openbao-ctrl-YYYYMMDDTHHMMSSZ.tar.gz.gpg
```

Le playbook :
- archive `init.vault.yml`, `vault.yml`, `pki/`,
- chiffre en AES256 symétrique GPG,
- shred l'archive en clair,
- calcule SHA256 pour vérification d'intégrité,
- fait tourner les fichiers >30 jours.

### 3bis.2 Synchroniser vers stockage externe

**Indispensable** : le playbook ne fait que créer le fichier chiffré localement. La synchronisation hors machine doit être faite séparément (volontaire — on ne veut pas que la passphrase de chiffrement ou un token cloud transite par Ansible).

Exemples :

```bash
# Vers un NAS via rsync (mTLS recommandé)
rsync -av --remove-source-files \
  ~/openbao-controller-backups/openbao-ctrl-*.tar.gz.gpg \
  backup-nas:/srv/openbao/

# Vers S3-compatible
aws s3 cp ~/openbao-controller-backups/openbao-ctrl-*.tar.gz.gpg \
  s3://openbao-backup-bucket/ --sse AES256

# Vers USB hardware-encrypted (Yubikey, IronKey)
cp ~/openbao-controller-backups/openbao-ctrl-*.tar.gz.gpg /media/usb-secure/
```

À automatiser via cron OS du contrôleur (pas Ansible) :

```cron
# /etc/cron.d/openbao-backup-sync
0 3 * * * massi rsync -av --remove-source-files /home/massi/openbao-controller-backups/*.tar.gz.gpg backup-nas:/srv/openbao/
```

### 3bis.3 Restauration

Sur n'importe quelle machine équipée d'`ansible` + `gpg` :

```bash
# Récupérer le fichier .tar.gz.gpg depuis le stockage externe
# Vérifier intégrité
sha256sum -c openbao-ctrl-YYYYMMDDTHHMMSSZ.tar.gz.gpg.sha256

# Déchiffrer + extraire
gpg --decrypt --passphrase-file ~/.openbao/backup.pass \
  openbao-ctrl-YYYYMMDDTHHMMSSZ.tar.gz.gpg | tar -xzf -
# → restaure inventories/.../init.vault.yml + vault.yml + pki/

# Vérifier que ansible-vault peut déchiffrer init.vault.yml
ansible-vault view inventories/production/group_vars/all/init.vault.yml
```

### 3bis.4 Politique de rétention

| Emplacement | Rétention | Fréquence |
|---|---|---|
| Local contrôleur | 30 jours | quotidien |
| NAS / S3 | 1 an | quotidien |
| USB hardware (offline) | 5 ans | mensuel |

La passphrase GPG est conservée par 2 personnes habilitées dans 2 KeePass distincts (rotation tous les 6 mois). Sans elle, les sauvegardes sont inutilisables.

---

## 4. Restore depuis snapshot

> **Procédure d'urgence — perte totale du cluster, corruption Raft.** À ne jamais exécuter sans validation explicite du responsable de la sécurité.

### 4.1 Conséquences

Le restore **remplace l'état complet** du cluster. Les conséquences immédiates : tous les tokens existants sont invalidés (re-authentification de tous les clients), les leases en cours sont perdus, le cluster doit être re-unsealed avec les clés Shamir d'**origine** (pas celles d'après le restore).

### 4.2 Procédure

Sur le futur nœud leader (typiquement `bao-node-1` après reconstruction) :

```bash
# Le service doit être démarré, initialisé et unsealed
bao status

# Authentification avec le root token
bao login <root_token_origine>

# Restore (le -force est requis si le cluster contient des données)
bao operator raft snapshot restore -force /chemin/vers/snapshot.snap
```

### 4.3 Reconstruction du quorum

Les autres nœuds doivent être **rejoints proprement** :

```bash
# Sur bao-node-2 et bao-node-3
sudo systemctl stop openbao
sudo rm -rf /var/lib/openbao/raft/*
sudo systemctl start openbao
# Le retry_join se fait automatiquement, puis unseal manuel
```

### 4.4 Re-test post-restore

Vérifier `bao operator raft list-peers`, l'état de l'audit log, faire un `bao kv get` sur un secret de référence connu pour confirmer la cohérence.

---

## 5. Rotation des certificats TLS

### 5.1 Cas de routine (échéance, conformité)

Régénération depuis le contrôleur Ansible :

```bash
ansible-playbook playbooks/pki.yml --ask-vault-pass
```

Cela régénère les certs hôtes (la CA reste la même tant que sa clé privée n'est pas compromise). Puis, **nœud par nœud**, en respectant le quorum :

```bash
ansible-playbook playbooks/site.yml --limit bao-node-1 --tags openbao,tls,config --ask-vault-pass
ssh bao-node-1 "sudo systemctl restart openbao"
# → bao-node-1 est re-sealed → 3 opérateurs unseal
# Attendre que list-peers montre node-1 voter, puis enchaîner sur node-2 puis node-3
```

### 5.2 Cas de compromission de la CA

Régénération complète : nouvelle CA, nouveaux certs hôtes, redéploiement intégral, rolling restart, **et** distribution de la nouvelle CA aux clients (applications, scripts CI/CD) qui doivent en avoir une copie pour valider le serveur.

---

## 6. Ajout d'un nœud

> Cas d'usage : passer de 3 à 5 nœuds (par exemple deux DC supplémentaires) ou remplacer un nœud HS.

### 6.1 Préparation

1. Provisionner la VM Debian 13 (Trixie) conformément au standard.
2. Ajouter l'entrée dans `inventories/production/hosts.yml` (groupe `openbao`, avec `openbao_node_id`, `openbao_az`, `ansible_host`).
3. Déclarer son FQDN/IP dans le DNS interne.

### 6.2 Génération de son certificat

```bash
ansible-playbook playbooks/pki.yml --ask-vault-pass
# → produit ./pki/<nouveau_host>.crt et .key
```

### 6.3 Déploiement et join

```bash
ansible-playbook playbooks/site.yml --limit <nouveau_host> --ask-vault-pass
```

Le service démarre, fait `retry_join` automatiquement vers les nœuds existants, et arrive en état `sealed`. Procéder à l'unseal (3 opérateurs).

### 6.4 Vérification

```bash
bao operator raft list-peers
# Le nouveau nœud doit apparaître en "follower" et "voter: true"
```

> ⚠️ Avec 4 nœuds, le quorum passe à 3. Avec 5, à 3 aussi. Toujours préférer un **nombre impair** de nœuds.

---

## 7. Retrait d'un nœud

### 7.1 Retrait propre

Depuis le leader :

```bash
bao operator raft remove-peer <node_id_à_retirer>
```

Puis sur le nœud retiré :

```bash
sudo systemctl stop openbao
sudo systemctl disable openbao
sudo rm -rf /var/lib/openbao/raft/*
```

### 7.2 Mise à jour de l'inventaire

Retirer l'entrée du groupe `openbao` dans `inventories/production/hosts.yml`. Ajuster les `retry_join` dans la config des nœuds restants en relançant :

```bash
ansible-playbook playbooks/site.yml --tags openbao,config --ask-vault-pass
```

(pas besoin de restart car la config Raft est dynamique côté runtime).

---

## 8. Dépannage

### 8.1 Logs

| Source | Commande |
|---|---|
| Service OpenBao | `journalctl -u openbao -f` |
| Audit applicatif | `tail -f /var/log/openbao/audit.log` |
| HAProxy | `journalctl -u haproxy -f` |
| Failover FIP (service + timer) | `journalctl -u openbao-fip-failover.service -u openbao-fip-failover.timer -f` |

### 8.2 État du cluster

```bash
bao status                                    # état du nœud local
bao operator raft list-peers                  # vue cluster (depuis n'importe quel nœud)
bao operator raft autopilot state             # santé Raft
curl -k https://127.0.0.1:8200/v1/sys/health  # codes 200/429/472/473/501/503
```

| Code HTTP | Signification |
|---|---|
| 200 | Leader actif, prêt |
| 429 | Standby, prêt à servir des lectures |
| 472 | DR secondary |
| 473 | Performance standby |
| 501 | Non initialisé |
| 503 | Sealed |

### 8.3 Santé HAProxy

Page stats sur `https://<haproxy>:8404/stats` (auth `admin` / mot de passe vault). Vérifier la colonne `Status` : `UP` pour les nœuds disponibles, `DOWN` pour les sealed/down. La colonne `Cur` indique les sessions actives.

### 8.4 Vérification de la Floating IP

```bash
# Depuis n'importe quel HAProxy (le clouds.yaml y est déployé)
sudo -u openbao-fip env OS_CLIENT_CONFIG_FILE=/etc/openstack/clouds.yaml \
  openstack --os-cloud openbao_fip floating ip show <fip_uuid> -f table
# → Champ port_id doit pointer vers le port du HAProxy sain

# État persistant du script (streaks OK/KO)
cat /var/lib/openbao-fip/health.json

# Derniers cycles du timer
systemctl list-timers openbao-fip-failover.timer
journalctl -u openbao-fip-failover.service -n 50
```

**Bascule manuelle** : `openstack --os-cloud openbao_fip floating ip set --port $(openstack port list --server <ha-X> -f value -c ID | head -1) <fip_uuid>`. Avec `fip_takeover_policy=preempt` et ha-1 sain, le script ramènera la FIP au tick suivant.

**Causes fréquentes de non-bascule** : `403 Forbidden` (compte Keystone manque les droits, cf. §0.6) ; `NotFoundException` (UUID FIP incorrect dans le vault) ; `Connection refused /v1/sys/health` mais HAProxy actif (OpenBao sealed → 503 → considéré KO) ; streaks à 0 (le timer ne tourne pas, vérifier `systemctl status openbao-fip-failover.timer`).

### 8.5 Cas typiques

**« Le service openbao ne démarre pas, code 1 »** : presque toujours un problème de mlock. Vérifier `getcap /usr/bin/bao` (doit retourner `cap_ipc_lock=ep`), puis `journalctl -u openbao` pour la stack précise.

**« retry_join boucle en erreur TLS »** : vérifier que le SAN du certificat du nœud cible inclut bien l'IP utilisée dans `cluster_addr` ET le FQDN. C'est le piège le plus fréquent.

**« HAProxy report tous les backends DOWN alors que les nœuds sont up »** : la CA interne n'est pas dans `/etc/haproxy/ca.crt`, ou nftables bloque la sortie HAProxy → OpenBao. Tester avec `openssl s_client -CAfile /etc/haproxy/ca.crt -connect bao-node-1:8200` puis `journalctl -u nftables` et `nft list ruleset`.

**« Un opérateur a perdu sa clé Shamir »** : avec un seuil 5/3, on peut perdre **2 clés sur 5** sans incident. Au-delà, **regénération des unseal keys obligatoire** via `bao operator rekey -init -key-shares=5 -key-threshold=3` et nouvelle cérémonie.


---

## 9. Observabilité (Prometheus + alertes)

> Le rôle `openbao` expose nativement les métriques Prometheus sur `/v1/sys/metrics?format=prometheus`. Côté HAProxy, le port stats `8404` expose `/metrics`. Le projet fournit deux fichiers prêts à intégrer dans la stack supervision.

### 9.1 Configuration scrape Prometheus

Fichier `monitoring/prometheus-scrape.yml.j2` à intégrer dans le `prometheus.yml` du serveur de monitoring (sous `scrape_configs:`). Pré-requis :

```bash
# Créer un token avec policy auditor (lecture sys/metrics + sys/health)
bao login -method=token
bao token create -policy=auditor -orphan -ttl=8760h -format=json \
  | jq -r .auth.client_token > /etc/prometheus/openbao-auditor.token
chmod 600 /etc/prometheus/openbao-auditor.token

# Copier la CA interne pour valider le TLS OpenBao
cp /etc/openbao/tls/ca.crt /etc/prometheus/openbao-ca.crt
```

### 9.2 Règles dalerte

Fichier `monitoring/alerts.yml` (10 règles). Couvre :

| Alerte | Sévérité | Délai |
|---|---|---|
| `OpenBaoSealed` | critical | 1m |
| `OpenBaoLeaderLost` | critical | 30s |
| `OpenBaoLeaderFlapping` | warning | 5m |
| `OpenBaoMfaFailureSpike` | warning | 5m |
| `OpenBaoAuditLogWriteFailure` | critical | 1m |
| `OpenBaoRaftSnapshotStale` | warning | 30m (>7h) |
| `OpenBaoCertExpiringSoon` | warning | <14j |
| `OpenBaoTokenStoreFull` | warning | >50k |
| `HAProxyBackendDown` | critical | 1m |
| `FloatingIPNotMigrated` | critical | 2m |

À intégrer dans Prometheus :

```yaml
# /etc/prometheus/prometheus.yml
rule_files:
  - rules/openbao.yml
```

Puis : `cp monitoring/alerts.yml /etc/prometheus/rules/openbao.yml && systemctl reload prometheus`.

### 9.3 Dashboards Grafana

À récupérer (non fournis dans ce repo, hors scope) :
- HashiCorp Vault Cluster Overview (compatible OpenBao)
- HAProxy 2.x stats
- Node Exporter pour les métriques système des 5 VMs

