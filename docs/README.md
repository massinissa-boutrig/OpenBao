# Documentation — Terminaison SSL/TLS avec Octavia

Cette documentation décrit comment gérer la terminaison SSL/TLS sur le load balancer
**Octavia** (LBaaS d'OpenStack), de la préparation des certificats jusqu'aux scénarios
avancés, ainsi qu'un pont d'intégration avec **OpenBao**.

## Sommaire

| Document | Contenu |
|----------|---------|
| [`01-octavia-ssl-termination.md`](./01-octavia-ssl-termination.md) | Concepts, préparation Barbican, listener `TERMINATED_HTTPS`, création du LB |
| [`02-scenarios-avances.md`](./02-scenarios-avances.md) | SNI multi-domaines, re-chiffrement bout-en-bout, passthrough, politiques TLS |
| [`03-openbao-vers-barbican.md`](./03-openbao-vers-barbican.md) | Émission de certificats via OpenBao PKI et synchronisation vers Barbican |

## Pré-requis

- Un cloud OpenStack avec **Octavia** déployé et le service **Barbican** disponible.
- Le client `openstack` configuré (variables `OS_*` ou fichier `clouds.yaml`).
- `openssl` pour la manipulation des certificats.
- Pour la section OpenBao : un serveur **OpenBao** accessible avec le moteur secret **PKI** activé.

## Conventions

- Les valeurs entre `<chevrons>` sont à remplacer par les identifiants de votre environnement.
- Les commandes utilisent `--wait` pour bloquer jusqu'à ce que la ressource soit `ACTIVE`.
- Les exemples supposent un VIP sur un subset réseau déjà existant.
