# OpenBao HA — Déploiement Ansible multi-datacenter

> Projet Ansible *production-grade* pour déployer **OpenBao** (fork open-source de HashiCorp Vault) en haute disponibilité sur trois datacenters, avec un cluster Raft unique partagé, des frontaux HAProxy actif/passif par DC et des VIP keepalived.

---

## Sommaire

1. [Vue d'ensemble](#1-vue-densemble)
2. [Architecture](#2-architecture)
3. [Choix d'architecture et justifications](#3-choix-darchitecture-et-justifications)
4. [Plan d'adressage et ports](#4-plan-dadressage-et-ports)
5. [Prérequis](#5-prérequis)
6. [Installation pas-à-pas](#6-installation-pas-à-pas)
7. [Structure du projet](#7-structure-du-projet)
8. [Sécurité et hardening](#8-sécurité-et-hardening)
9. [Exploitation](#9-exploitation)
10. [Limitations connues](#10-limitations-connues)
11. [Références](#11-références)

---

## 1. Vue d'ensemble

| Élément | Valeur |
|---|---|
| **Produit déployé** | OpenBao (fork open-source de HashiCorp Vault) |
| **Mode HA** | Cluster Raft unique de 3 nœuds, un nœud par DC |
| **Storage backend** | Raft Integrated Storage (pas de backend externe) |
| **Seal/Unseal** | Shamir manuel — 5 parts, seuil de 3 |
| **Load-balancing** | HAProxy en TCP passthrough, roundrobin |
| **VIP** | 1 VIP par DC, gérée par keepalived (VRRP) |
| **TLS** | PKI interne, mTLS inter-nœuds, TLS 1.3 obligatoire |
| **OS cible** | RHEL 9 (compatible Rocky 9 / AlmaLinux 9) |
| **Hyperviseur** | Proxmox VE |

Le cluster OpenBao est **unique et partagé** entre les trois datacenters : un seul leader Raft à un instant T, deux *standby* qui répliquent l'état. Chaque DC dispose de sa propre VIP frontale (HAProxy actif/passif) qui distribue le trafic *en roundrobin sur les trois nœuds OpenBao* — c'est OpenBao lui-même qui forwarde les écritures vers le leader (le standby relaie de manière transparente).

---

## 2. Architecture

### 2.1 Schéma logique (Mermaid)

```mermaid
flowchart TB
    classDef client fill:#e8f4ff,stroke:#1f6feb,color:#0b3d91
    classDef vip fill:#dcfce7,stroke:#16a34a,stroke-dasharray:5 3,color:#14532d
    classDef ha fill:#dbeafe,stroke:#2563eb,color:#1e3a8a
    classDef bao fill:#fef3c7,stroke:#d97706,color:#7c2d12
    classDef dc fill:#f8fafc,stroke:#475569,stroke-width:2px

    Clients["👥 Clients<br/>(applications, opérateurs, CI/CD)"]:::client

    subgraph DC_A ["🏢 Datacenter A"]
        direction TB
        VIPA(["🟢 VIP A<br/>vip-bao-a.intra"]):::vip
        HAA1["HAProxy A1<br/>MASTER · prio 110"]:::ha
        HAA2["HAProxy A2<br/>BACKUP · prio 100"]:::ha
        BAOA["🔐 bao-node-1<br/>Raft node-1"]:::bao
        VIPA -.VRRP id 51.- HAA1
        VIPA -.VRRP id 51.- HAA2
        HAA1 --- HAA2
    end

    subgraph DC_B ["🏢 Datacenter B"]
        direction TB
        VIPB(["🟢 VIP B<br/>vip-bao-b.intra"]):::vip
        HAB1["HAProxy B1<br/>MASTER · prio 110"]:::ha
        HAB2["HAProxy B2<br/>BACKUP · prio 100"]:::ha
        BAOB["🔐 bao-node-2<br/>Raft node-2"]:::bao
        VIPB -.VRRP id 52.- HAB1
        VIPB -.VRRP id 52.- HAB2
        HAB1 --- HAB2
    end

    subgraph DC_C ["🏢 Datacenter C"]
        direction TB
        VIPC(["🟢 VIP C<br/>vip-bao-c.intra"]):::vip
        HAC1["HAProxy C1<br/>MASTER · prio 110"]:::ha
        HAC2["HAProxy C2<br/>BACKUP · prio 100"]:::ha
        BAOC["🔐 bao-node-3<br/>Raft node-3"]:::bao
        VIPC -.VRRP id 53.- HAC1
        VIPC -.VRRP id 53.- HAC2
        HAC1 --- HAC2
    end

    class DC_A,DC_B,DC_C dc

    Clients ==>|HTTPS 8200| VIPA
    Clients ==>|HTTPS 8200| VIPB
    Clients ==>|HTTPS 8200| VIPC

    HAA1 -.TCP passthrough.-> BAOA
    HAA1 -.TCP passthrough.-> BAOB
    HAA1 -.TCP passthrough.-> BAOC
    HAB1 -.TCP passthrough.-> BAOA
    HAB1 -.TCP passthrough.-> BAOB
    HAB1 -.TCP passthrough.-> BAOC
    HAC1 -.TCP passthrough.-> BAOA
    HAC1 -.TCP passthrough.-> BAOB
    HAC1 -.TCP passthrough.-> BAOC

    BAOA <==>|Raft mTLS 8201| BAOB
    BAOB <==>|Raft mTLS 8201| BAOC
    BAOA <==>|Raft mTLS 8201| BAOC
```

### 2.2 Lecture du schéma

Trois flux distincts circulent sur l'infrastructure. Le **flux client** (trait épais) part de n'importe quelle application et arrive sur la VIP du DC le plus proche, en HTTPS sur le port 8200 ; aucune logique d'affinité, le client peut taper n'importe quelle VIP. Le **flux load-balancing** (trait pointillé) descend de la VIP active vers HAProxy puis vers les trois nœuds OpenBao en TCP passthrough — la session TLS est terminée *par OpenBao*, jamais par HAProxy. Le **flux Raft** (trait épais bidirectionnel) est la réplication permanente entre les trois nœuds sur le port 8201 en mTLS, c'est lui qui garantit la cohérence du cluster.

### 2.3 Comportement en cas de panne

Si un HAProxy MASTER tombe, keepalived bascule la VIP sur le BACKUP du même DC en moins de 3 secondes (script de check toutes les 2 s, transition VRRP immédiate). Si un nœud OpenBao tombe, les deux survivants conservent le quorum Raft (2/3) et continuent de servir : Raft élit un nouveau leader si nécessaire en quelques secondes. Si un DC entier tombe, les deux DC restants conservent le quorum (2/3) — le service reste disponible via les VIP des deux autres DC. **Si deux DC tombent simultanément, le quorum est perdu** : le cluster passe en lecture seule jusqu'au retour d'au moins un nœud, c'est le compromis assumé d'une topologie 1+1+1.

---

## 3. Choix d'architecture et justifications

| Décision | Choix | Justification |
|---|---|---|
| Storage backend | Raft Integrated | Pas de SPOF externe, snapshots intégrés, c'est le standard recommandé en 2024+ |
| Seal | Shamir 5/3 manuel | Pas de dépendance externe (KMS/HSM) qui deviendrait elle-même critique |
| Distribution clés | 5 opérateurs distincts, coffres individuels | Pas d'unseal automatique = pas de point unique de compromission |
| TLS | PKI interne dédiée, TLS 1.3 only | Maîtrise totale du cycle de vie des certificats, pas de dépendance externe |
| HAProxy mode | TCP passthrough | OpenBao garde la terminaison TLS de bout en bout |
| Algorithme LB | roundrobin sans stickiness | OpenBao redirige nativement les écritures vers le leader |
| Healthcheck | `GET /v1/sys/health?standbyok=true&perfstandbyok=true` accept 200/429 | Standby utile pour les lectures, leader pour les écritures |
| VIP | keepalived VRRP, 1 VIP/DC | Pas de dépendance à du BGP ou de l'anycast |
| Hardening systemd | Capabilities minimales + sandboxing complet | Réduction maximale de la surface d'attaque kernel |
| Quorum | 3 nœuds 1+1+1 | Tolère la perte d'un DC complet |

---

## 4. Plan d'adressage et ports

### 4.1 Ports

| Port | Usage | Exposition firewalld |
|---|---|---|
| `8200/tcp` | API OpenBao (TLS 1.3) | Zone `public` ouverte |
| `8201/tcp` | Cluster Raft (mTLS) | Restreint aux IPs des pairs Raft (rich rules) |
| `8200/tcp` | VIP HAProxy frontend | Zone `public` ouverte |
| `8404/tcp` | HAProxy stats | Restreint aux IPs de supervision |
| `protocole 112` | VRRP keepalived | Restreint au pair HAProxy du même DC |

### 4.2 Inventaire (modèle)

| Hostname | DC | Rôle | IP exemple | VIP |
|---|---|---|---|---|
| `bao-node-1` | A | OpenBao | `10.10.1.10` | — |
| `bao-node-2` | B | OpenBao | `10.10.2.10` | — |
| `bao-node-3` | C | OpenBao | `10.10.3.10` | — |
| `ha-a1` | A | HAProxy MASTER | `10.10.1.11` | `10.10.1.100` |
| `ha-a2` | A | HAProxy BACKUP | `10.10.1.12` | `10.10.1.100` |
| `ha-b1` | B | HAProxy MASTER | `10.10.2.11` | `10.10.2.100` |
| `ha-b2` | B | HAProxy BACKUP | `10.10.2.12` | `10.10.2.100` |
| `ha-c1` | C | HAProxy MASTER | `10.10.3.11` | `10.10.3.100` |
| `ha-c2` | C | HAProxy BACKUP | `10.10.3.12` | `10.10.3.100` |

### 4.3 DNS attendu

Trois enregistrements A (un par VIP) : `vip-bao-a.intra`, `vip-bao-b.intra`, `vip-bao-c.intra`. Optionnellement un enregistrement *round-robin DNS* `bao.intra` pointant vers les trois VIP, à laisser au client le choix de basculer.

---

## 5. Prérequis

Côté contrôleur Ansible : Ansible 2.14+, Python 3.9+, accès SSH (clé) avec `sudo` sans mot de passe vers tous les hôtes cibles, les collections listées dans `requirements.yml`, et un Ansible Vault initialisé (`ansible-vault create inventories/production/group_vars/all/vault.yml`).

Côté hôtes cibles : RHEL 9 / Rocky 9 / AlmaLinux 9 fraîchement installé, `firewalld` et `selinux` activés (enforcing), résolution DNS interne fonctionnelle pour tous les FQDN du cluster, accès sortant aux GitHub releases pour télécharger le binaire OpenBao (ou un mirror interne).

Côté humains : cinq opérateurs identifiés et formés pour détenir chacun **une** part Shamir, avec leur propre coffre offline (KeePass, YubiKey, etc.). **Sans ces cinq personnes, l'unseal après reboot est impossible.**

---

## 6. Installation pas-à-pas

```bash
# 1. Récupérer les collections Ansible
ansible-galaxy collection install -r requirements.yml

# 2. Créer le vault avec les secrets sensibles
ansible-vault create inventories/production/group_vars/all/vault.yml
# → renseigner pki_ca_passphrase, haproxy_stats_password, keepalived_auth_pass

# 3. Compléter l'inventaire
vim inventories/production/hosts.yml
# → IPs, hostnames, interface réseau, etc.

# 4. Renseigner la version OpenBao et son checksum
vim inventories/production/group_vars/all/main.yml
# → openbao_version, openbao_checksum_sha256 (depuis GitHub releases)

# 5. Générer la PKI interne (sur le contrôleur)
ansible-playbook playbooks/pki.yml --ask-vault-pass

# 6. Déployer toute l'infrastructure
ansible-playbook playbooks/site.yml --ask-vault-pass

# 7. Initialiser le cluster — UNE SEULE FOIS, depuis bao-node-1
ssh bao-node-1
sudo -u openbao bao operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/init.json
# → distribuer immédiatement les 5 unseal keys et le root token, puis :
shred -u /tmp/init.json

# 8. Unseal des 3 nœuds (3 clés différentes par nœud)
# Voir docs/RUNBOOK.md section "Initialisation du cluster"
```

À l'issue de ces étapes, `bao operator raft list-peers` doit montrer les trois nœuds en *voter*, et un `curl -k https://vip-bao-a.intra:8200/v1/sys/health` doit retourner un 200 ou un 429.

---

## 7. Structure du projet

```
openbao-ha/
├── README.md                          ← ce fichier
├── ansible.cfg
├── requirements.yml
├── playbooks/
│   ├── site.yml                       ← orchestration complète
│   ├── pki.yml                        ← génération CA + certs hôtes
│   └── backup.yml                     ← snapshot Raft du leader
├── inventories/production/
│   ├── hosts.yml                      ← inventaire des 9 VMs
│   └── group_vars/
│       ├── all/
│       │   ├── main.yml               ← variables globales
│       │   └── vault.yml.example      ← squelette du vault
│       ├── openbao.yml
│       └── haproxy.yml
├── roles/
│   ├── openbao/                       ← rôle principal (binaire, TLS, config, systemd, firewalld)
│   ├── haproxy/                       ← TCP passthrough + healthcheck OpenBao
│   └── keepalived/                    ← VRRP + script check_haproxy
└── docs/
    ├── RUNBOOK.md                     ← procédures d'exploitation
    └── architecture.drawio            ← schéma éditable draw.io
```

---

## 8. Sécurité et hardening

L'unit systemd `openbao.service` applique un sandboxing systemd complet : capabilities réduites au strict `CAP_IPC_LOCK` (nécessaire pour mlock), `ProtectSystem=strict`, `ProtectKernelTunables/Modules/Logs=true`, `PrivateTmp/Devices=true`, `NoNewPrivileges=true`, `MemoryDenyWriteExecute=true`, filtrage `SystemCallFilter=@system-service` excluant `@privileged`, `@resources`, `@mount`, `@swap`, `@reboot`, `@debug`. Les écritures sont restreintes par `ReadWritePaths` au seul `data_dir` et `log_dir`. Le service tourne sous l'utilisateur dédié `openbao` (system, nologin), jamais root.

Le binaire `bao` reçoit la capability `cap_ipc_lock=+ep` via `setcap`, ce qui permet d'utiliser `mlock()` sans tourner en root et donc d'empêcher le swap des secrets sur disque (`disable_mlock = false` dans la config).

Le firewalld n'expose que ce qui est strictement nécessaire : 8200/tcp en zone publique pour l'API, 8201/tcp uniquement aux IPs des autres pairs Raft via rich rules. SELinux reste en `enforcing` ; les seules booléens activés sont `haproxy_connect_any` et `keepalived_connect_any`, justifiés par le fonctionnement attendu de ces démons.

Les secrets sensibles (passphrase de la CA, mot de passe stats HAProxy, mot de passe VRRP) sont dans Ansible Vault. **Les unseal keys Shamir et le root token ne sont JAMAIS dans Ansible Vault** — ils sont distribués manuellement à cinq opérateurs distincts, qui les conservent dans leur propre coffre offline.

---

## 9. Exploitation

Toute l'exploitation au quotidien est documentée dans [`docs/RUNBOOK.md`](docs/RUNBOOK.md), qui couvre :

- l'initialisation du cluster (unique et critique),
- l'unseal après chaque reboot (procédure 5 personnes / 3 clés),
- la prise et la restauration de snapshots Raft,
- la rotation des certificats TLS,
- l'ajout et le retrait d'un nœud,
- le dépannage (logs, statut cluster, santé HAProxy, VIP).

Un schéma éditable au format draw.io est fourni dans [`docs/architecture.drawio`](docs/architecture.drawio) pour diffusion interne et présentations.

---

## 10. Limitations connues

L'**initialisation et l'unseal sont manuels** — c'est un choix volontaire pour ne pas dépendre d'un KMS externe, mais cela signifie qu'un reboot du cluster impose la mobilisation de trois opérateurs habilités. La latence inter-DC impacte directement la latence d'écriture (consensus Raft) ; cette topologie suppose des liens inter-DC à moins de **10 ms RTT**, au-delà l'expérience client se dégrade. Il n'y a **pas de PRA automatique** vers un cluster secondaire — le DR repose sur les snapshots Raft réguliers (cf. `playbooks/backup.yml`) à restaurer manuellement. Enfin, la perte simultanée de deux DC sur trois entraîne la perte du quorum et bascule le cluster en lecture seule.

---

## 11. Références

- [OpenBao — documentation officielle](https://openbao.org/docs/)
- [OpenBao — GitHub releases](https://github.com/openbao/openbao/releases)
- [HashiCorp Raft — papier de référence](https://raft.github.io/)
- [Ansible collection `community.crypto`](https://docs.ansible.com/ansible/latest/collections/community/crypto/)
- [systemd — directives de sandboxing](https://www.freedesktop.org/software/systemd/man/systemd.exec.html)
- [HAProxy — documentation 2.4+](https://docs.haproxy.org/2.4/configuration.html)
