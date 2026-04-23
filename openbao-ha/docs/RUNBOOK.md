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

> **À lire avant tout déploiement.** Ce projet Ansible configure uniquement l'OS et les services — la création des VMs, des security groups, et de la VIP doit être faite en amont (Terraform, Heat, openstack CLI, ou console Horizon). Les éléments ci-dessous sont **indispensables** au bon fonctionnement de la HA.

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
| `haproxy-frontends` | TCP 8200 | subnet clients | Frontend VIP |
| `haproxy-frontends` | TCP 8404 | subnet supervision | Page stats HAProxy |
| `haproxy-frontends` | protocol 112 (VRRP) | `haproxy-frontends` | keepalived |

L'egress reste par défaut (all). nftables applique un second filtre local plus strict (policy drop).

### 0.3 VIP keepalived & allowed-address-pairs

OpenStack Neutron bloque par défaut tout trafic dont l'IP source ne correspond pas à celle du port. Or, keepalived fait flotter `10.10.0.100` entre ha-1 et ha-2 → il faut autoriser explicitement cette IP en `allowed-address-pairs` sur **les deux** ports Neutron des HAProxy.

```bash
# Récupérer les IDs des ports
PORT_HA1=$(openstack port list --server ha-1 -f value -c ID)
PORT_HA2=$(openstack port list --server ha-2 -f value -c ID)

# Autoriser la VIP
openstack port set --allowed-address ip-address=10.10.0.100 $PORT_HA1
openstack port set --allowed-address ip-address=10.10.0.100 $PORT_HA2
```

Sans cela, le trafic vers la VIP sera silencieusement droppé par Neutron après la bascule keepalived.

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
| Keepalived | `journalctl -u keepalived -f` |

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

### 8.4 Vérification de la VIP

```bash
ssh ha-a1
ip addr show <interface>     # la VIP doit apparaître sur le MASTER actif
```

Si la VIP n'apparaît nulle part : `journalctl -u keepalived` sur les deux pairs, vérifier que VRRP n'est pas bloqué par nftables (le set `vrrp_peers` doit contenir l'IP du pair, vérifier avec `nft list set inet filter vrrp_peers`).

### 8.5 Cas typiques

**« Le service openbao ne démarre pas, code 1 »** : presque toujours un problème de mlock. Vérifier `getcap /usr/bin/bao` (doit retourner `cap_ipc_lock=ep`), puis `journalctl -u openbao` pour la stack précise.

**« retry_join boucle en erreur TLS »** : vérifier que le SAN du certificat du nœud cible inclut bien l'IP utilisée dans `cluster_addr` ET le FQDN. C'est le piège le plus fréquent.

**« HAProxy report tous les backends DOWN alors que les nœuds sont up »** : la CA interne n'est pas dans `/etc/haproxy/ca.crt`, ou nftables bloque la sortie HAProxy → OpenBao. Tester avec `openssl s_client -CAfile /etc/haproxy/ca.crt -connect bao-node-1:8200` puis `journalctl -u nftables` et `nft list ruleset`.

**« Un opérateur a perdu sa clé Shamir »** : avec un seuil 5/3, on peut perdre **2 clés sur 5** sans incident. Au-delà, **regénération des unseal keys obligatoire** via `bao operator rekey -init -key-shares=5 -key-threshold=3` et nouvelle cérémonie.
