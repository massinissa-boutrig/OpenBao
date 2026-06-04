# 01 — Terminaison SSL/TLS avec Octavia

## Principe

Dans le mode **terminaison SSL**, le load balancer déchiffre le trafic TLS entrant,
puis transmet la requête en **HTTP clair** vers les serveurs backend (pool members).

```
Client ──HTTPS──> [ Octavia LB : TERMINATED_HTTPS ] ──HTTP──> Backends
                          │
                          └── lit le certificat depuis Barbican
```

Le certificat ne réside **jamais** sur les serveurs applicatifs : il est stocké dans
**Barbican** (le secret store d'OpenStack), et Octavia y fait référence via un *secret href*.

Avantages : centralisation des certificats, déchargement TLS des backends, et accès aux
fonctions L7 (routage par URL, en-têtes, etc.) puisque le LB voit le trafic en clair.

## Étape 1 — Préparer le certificat dans Barbican

Octavia attend un bundle **PKCS#12** contenant la clé privée, le certificat serveur et
la chaîne d'autorité de certification.

```bash
# Construire le PKCS12 (sans mot de passe ici ; voir note ci-dessous)
openssl pkcs12 -export \
  -inkey server.key \
  -in server.crt \
  -certfile ca-chain.crt \
  -passout pass: \
  -out server.p12

# Stocker le bundle dans Barbican
openstack secret store \
  --name 'mon-cert-tls' \
  --secret-type 'opaque' \
  -t 'application/octet-stream' \
  -e 'base64' \
  --payload "$(base64 < server.p12)"
```

La commande retourne un **Secret href** du type :

```
https://<keystone>/key-manager/v1/secrets/<uuid>
```

Conservez-le : c'est la référence utilisée par le listener.

> **Note mot de passe** — si votre PKCS#12 est protégé par un mot de passe, Octavia ne
> pourra pas le lire. Générez-le sans mot de passe (`-passout pass:`) ou utilisez un
> *certificate container* Barbican avec un secret de passphrase associé.

## Étape 2 — Autoriser Octavia à lire le secret

Octavia accède aux secrets avec son **compte de service**. Le projet propriétaire du secret
doit ajouter une ACL Barbican autorisant cet utilisateur :

```bash
# Récupérer l'ID utilisateur du service Octavia auprès de l'admin du cloud
openstack acl user add -u <octavia-service-user-id> <secret-href>
```

Sans cette ACL, la création du listener échoue avec une erreur d'accès au secret.

## Étape 3 — Créer le load balancer

```bash
openstack loadbalancer create \
  --name lb1 \
  --vip-subnet-id <subnet-id> \
  --wait
```

## Étape 4 — Créer le listener `TERMINATED_HTTPS`

```bash
openstack loadbalancer listener create lb1 \
  --name https-listener \
  --protocol TERMINATED_HTTPS \
  --protocol-port 443 \
  --default-tls-container-ref <secret-href> \
  --wait
```

C'est ici que la terminaison TLS est activée : `--protocol TERMINATED_HTTPS` indique à
Octavia de déchiffrer, et `--default-tls-container-ref` pointe vers le certificat Barbican.

## Étape 5 — Créer le pool en HTTP

Le trafic vers les backends étant déchiffré, le **pool est en `HTTP`** :

```bash
openstack loadbalancer pool create \
  --name pool1 \
  --listener https-listener \
  --protocol HTTP \
  --lb-algorithm ROUND_ROBIN \
  --wait
```

## Étape 6 — Ajouter les membres et un health monitor

```bash
openstack loadbalancer member create pool1 \
  --address <ip-backend-1> --protocol-port 80 --wait
openstack loadbalancer member create pool1 \
  --address <ip-backend-2> --protocol-port 80 --wait

openstack loadbalancer healthmonitor create pool1 \
  --type HTTP --url-path /healthz \
  --delay 5 --timeout 3 --max-retries 3 --wait
```

## Récapitulatif des protocoles

| Composant | Protocole | Rôle |
|-----------|-----------|------|
| Listener | `TERMINATED_HTTPS` | Déchiffre le TLS entrant |
| Pool | `HTTP` | Transmet en clair aux backends |
| Members | `HTTP` (port 80) | Serveurs applicatifs |

## Vérification

```bash
openstack loadbalancer show lb1
openstack loadbalancer listener show https-listener
# Test depuis un client
curl -v https://<vip-address>/ --resolve <fqdn>:443:<vip-address>
```

Le passage à `provisioning_status: ACTIVE` et `operating_status: ONLINE` confirme que
la terminaison fonctionne.

Voir [`02-scenarios-avances.md`](./02-scenarios-avances.md) pour SNI, le re-chiffrement
et les politiques TLS.
