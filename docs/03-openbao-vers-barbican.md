# 03 — Pont OpenBao → Barbican pour Octavia

## Contexte

Octavia **ne s'intègre pas nativement** avec OpenBao (ni HashiCorp Vault) : il lit
exclusivement ses certificats depuis **Barbican**. Si OpenBao est votre autorité de
certification (moteur secret **PKI**), il faut donc un pont qui :

1. fait émettre le certificat par OpenBao,
2. le convertit au format PKCS#12 attendu par Octavia,
3. le pousse dans Barbican,
4. met à jour le listener Octavia pour pointer sur le nouveau secret.

```
[ OpenBao PKI ] ──émet cert──> [ script de synchro ] ──store──> [ Barbican ] ──ref──> [ Octavia ]
```

> **Avertissement** — il s'agit d'un workflow d'intégration, pas d'une fonctionnalité
> supportée d'Octavia. Testez-le en pré-production et sécurisez le compte qui exécute la
> synchronisation (accès OpenBao **et** Barbican).

## Étape 1 — Émettre le certificat depuis OpenBao

En supposant un moteur PKI monté sur `pki/` et un rôle `octavia` configuré :

```bash
export BAO_ADDR='https://openbao.example.com:8200'
export BAO_TOKEN='<token-avec-droits-pki>'

bao write -format=json pki/issue/octavia \
  common_name="app.example.com" \
  alt_names="www.example.com" \
  ttl="720h" > /tmp/issued.json
```

Le JSON retourné contient `certificate`, `private_key`, `issuing_ca` et `ca_chain`.

## Étape 2 — Construire le PKCS#12

```bash
jq -r '.data.certificate'  /tmp/issued.json > /tmp/server.crt
jq -r '.data.private_key'  /tmp/issued.json > /tmp/server.key
jq -r '.data.ca_chain[]'   /tmp/issued.json > /tmp/ca-chain.crt

openssl pkcs12 -export \
  -inkey /tmp/server.key \
  -in /tmp/server.crt \
  -certfile /tmp/ca-chain.crt \
  -passout pass: \
  -out /tmp/server.p12
```

## Étape 3 — Pousser dans Barbican et mettre à jour Octavia

```bash
SECRET_HREF=$(openstack secret store \
  --name "octavia-$(date +%Y%m%d%H%M)" \
  -t 'application/octet-stream' -e 'base64' \
  --payload "$(base64 < /tmp/server.p12)" \
  -f value -c 'Secret href')

# ACL pour le service Octavia
openstack acl user add -u <octavia-service-user-id> "$SECRET_HREF"

# Bascule du listener sur le nouveau certificat
openstack loadbalancer listener set https-listener \
  --default-tls-container-ref "$SECRET_HREF"
```

Octavia recharge la configuration de l'amphora ; la bascule est sans coupure côté listener.

## Script de synchronisation complet

Le script ci-dessous enchaîne les trois étapes et nettoie les fichiers temporaires.
Adaptez les variables en tête.

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ------------------------------------------------------------
: "${BAO_ADDR:?export BAO_ADDR}"
: "${BAO_TOKEN:?export BAO_TOKEN}"
PKI_ROLE="octavia"
COMMON_NAME="app.example.com"
ALT_NAMES="www.example.com"
TTL="720h"
LISTENER="https-listener"
OCTAVIA_USER_ID="<octavia-service-user-id>"
# -----------------------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Émission du certificat via OpenBao"
bao write -format=json "pki/issue/${PKI_ROLE}" \
  common_name="$COMMON_NAME" alt_names="$ALT_NAMES" ttl="$TTL" > "$WORK/issued.json"

jq -r '.data.certificate' "$WORK/issued.json" > "$WORK/server.crt"
jq -r '.data.private_key' "$WORK/issued.json" > "$WORK/server.key"
jq -r '.data.ca_chain[]'  "$WORK/issued.json" > "$WORK/ca-chain.crt"

echo "==> Construction du PKCS#12"
openssl pkcs12 -export \
  -inkey "$WORK/server.key" -in "$WORK/server.crt" \
  -certfile "$WORK/ca-chain.crt" -passout pass: -out "$WORK/server.p12"

echo "==> Stockage dans Barbican"
SECRET_HREF=$(openstack secret store \
  --name "octavia-$(date +%Y%m%d%H%M)" \
  -t 'application/octet-stream' -e 'base64' \
  --payload "$(base64 < "$WORK/server.p12")" \
  -f value -c 'Secret href')
echo "    secret: $SECRET_HREF"

echo "==> ACL pour Octavia"
openstack acl user add -u "$OCTAVIA_USER_ID" "$SECRET_HREF"

echo "==> Mise à jour du listener"
openstack loadbalancer listener set "$LISTENER" \
  --default-tls-container-ref "$SECRET_HREF"

echo "==> Terminé."
```

## Automatiser la rotation

Les certificats émis par OpenBao ont une **TTL courte par design**. Planifiez la synchro
avant expiration. Exemple cron (chaque dimanche à 3 h, pour une TTL de 720 h ≈ 30 j) :

```cron
0 3 * * 0  /opt/octavia/sync-cert.sh >> /var/log/octavia-cert-sync.log 2>&1
```

Recommandations :

- Utilisez un **token OpenBao à durée de vie limitée** ou une auth AppRole plutôt qu'un
  token root.
- Donnez au compte exécutant uniquement les droits PKI (émission) côté OpenBao et secret
  store + ACL côté Barbican.
- Conservez les anciens secrets quelques jours puis purgez-les
  (`openstack secret delete <href>`) une fois la bascule confirmée.
- Surveillez l'expiration : alertez si un certificat actif passe sous un seuil (p. ex. 7 j).

## Limites connues

- Pas de rollback automatique : si la bascule du listener échoue, l'ancien secret reste en
  place — vérifiez le `provisioning_status` après chaque `listener set`.
- Le PKCS#12 doit être **sans mot de passe** (cf. doc 01) sauf à gérer un container Barbican
  avec passphrase.
- Cette approche duplique le matériel cryptographique dans deux systèmes (OpenBao + Barbican) :
  traitez Barbican comme un magasin de distribution, OpenBao restant la source de vérité.
