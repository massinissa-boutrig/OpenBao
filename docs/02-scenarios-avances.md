# 02 — Scénarios avancés

Ce document couvre les variantes courantes au-delà de la terminaison HTTPS simple décrite
dans [`01-octavia-ssl-termination.md`](./01-octavia-ssl-termination.md).

## SNI — plusieurs domaines sur un même port

Le **SNI** (Server Name Indication) permet de servir plusieurs certificats sur le même
listener / port 443. Octavia choisit le certificat selon le hostname demandé par le client
dans le handshake TLS.

Préparez chaque certificat dans Barbican (cf. étape 1 du doc 01), puis :

```bash
openstack loadbalancer listener create lb1 \
  --name https-listener \
  --protocol TERMINATED_HTTPS \
  --protocol-port 443 \
  --default-tls-container-ref <secret-defaut> \
  --sni-container-refs <secret-domaine-a> <secret-domaine-b> <secret-domaine-c> \
  --wait
```

- `--default-tls-container-ref` : certificat utilisé si aucun SNI ne correspond.
- `--sni-container-refs` : liste des certificats candidats, sélectionnés par hostname.

Pour modifier la liste sur un listener existant :

```bash
openstack loadbalancer listener set https-listener \
  --sni-container-refs <secret-a> <secret-b>
```

## Re-chiffrement bout-en-bout (TLS jusqu'aux backends)

Pour conserver le chiffrement jusqu'aux serveurs applicatifs tout en gardant la visibilité
L7 sur le LB, on **termine puis re-chiffre** : le listener reste `TERMINATED_HTTPS`, mais
le **pool est activé en TLS**.

```bash
openstack loadbalancer pool create \
  --name pool-tls \
  --listener https-listener \
  --protocol HTTP \
  --lb-algorithm ROUND_ROBIN \
  --tls-enabled \
  --wait
```

Pour que le LB **valide** le certificat des backends (recommandé), fournissez le CA :

```bash
# Stocker le CA des backends dans Barbican
openstack secret store --name 'backend-ca' \
  -t 'application/octet-stream' -e 'base64' \
  --payload "$(base64 < backend-ca.crt)"

openstack loadbalancer pool set pool-tls \
  --ca-tls-container-ref <secret-backend-ca>
```

Options complémentaires :

- `--crl-container-ref <ref>` : liste de révocation pour les certs backend.
- `--tls-container-ref <ref>` : certificat **client** présenté par le LB aux backends (mTLS).

```
Client ──HTTPS──> [ Octavia : TERMINATED_HTTPS ] ──HTTPS──> Backends
                       déchiffre + re-chiffre
                       (visibilité L7 conservée)
```

## Passthrough — pas de terminaison sur le LB

Si vous ne voulez **pas** déchiffrer sur le load balancer (le certificat reste sur les
backends), utilisez un listener `HTTPS` simple. Le trafic traverse chiffré de bout en bout.

```bash
openstack loadbalancer listener create lb1 \
  --name passthrough-listener \
  --protocol HTTPS \
  --protocol-port 443 \
  --wait

openstack loadbalancer pool create \
  --name pool-passthrough \
  --listener passthrough-listener \
  --protocol HTTPS \
  --lb-algorithm ROUND_ROBIN \
  --wait
```

**Compromis** : aucun certificat à gérer dans Barbican, mais vous **perdez les fonctions
L7** (routage par URL, insertion d'en-têtes `X-Forwarded-*`, inspection). Le LB se comporte
en équilibreur de niveau transport.

| Mode | Listener | Déchiffrement LB | Visibilité L7 | Cert dans Barbican |
|------|----------|------------------|---------------|--------------------|
| Terminaison | `TERMINATED_HTTPS` | Oui | Oui | Oui |
| Re-chiffrement | `TERMINATED_HTTPS` + pool TLS | Oui (puis re-chiffre) | Oui | Oui |
| Passthrough | `HTTPS` | Non | Non | Non |

## Politiques TLS — versions et ciphers

Restreignez les versions de protocole et les suites cryptographiques au niveau du listener
(utile pour désactiver TLS 1.0/1.1 et imposer des ciphers modernes) :

```bash
openstack loadbalancer listener set https-listener \
  --tls-versions TLSv1.2 TLSv1.3 \
  --tls-ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305'
```

- `--tls-versions` : liste blanche des versions acceptées.
- `--tls-ciphers` : chaîne OpenSSL des suites autorisées (ordre = préférence).

Pour appliquer une politique par défaut à l'échelle du cloud, l'administrateur peut définir
`default_listener_ciphers` et `default_listener_tls_versions` dans `octavia.conf`.

## Redirection HTTP → HTTPS

Bonne pratique : un listener HTTP en port 80 qui redirige vers HTTPS via une L7 policy.

```bash
openstack loadbalancer listener create lb1 \
  --name http-listener --protocol HTTP --protocol-port 80 --wait

openstack loadbalancer l7policy create http-listener \
  --name redirect-https \
  --action REDIRECT_PREFIX \
  --redirect-prefix https://<fqdn> \
  --redirect-http-code 301 \
  --wait
```
