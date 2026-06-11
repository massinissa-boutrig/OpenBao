# Migration HAProxy + keepalived → OpenStack Octavia

> **Objet** : décrire les cas d'usage de répartition de charge couverts par Octavia et détailler la procédure pour remplacer une paire HAProxy autogérée (avec VIP keepalived) par un load balancer Octavia managé.
>
> **Périmètre** : 3 cas d'usage de référence
> 1. HTTP basique (L7, sans TLS)
> 2. HTTPS avec terminaison TLS portée par le load balancer (offloading)
> 3. Mode TCP « passthrough » : le backend gère lui-même la terminaison TLS
>
> Pour chaque cas : schéma logique, configuration HAProxy de départ, et équivalent Octavia en **OpenStack CLI**, **Terraform** et **API REST (curl)**.

---

## 1. Concepts Octavia et correspondance avec HAProxy

Octavia est le service de Load Balancing as a Service (LBaaS) d'OpenStack. Sous le capot, chaque load balancer est porté par une ou plusieurs VM dédiées appelées **amphorae**, qui exécutent... HAProxy. La logique métier est donc très proche, mais le modèle de données est différent : on ne décrit plus un fichier `haproxy.cfg`, on assemble des objets API.

### 1.1 Modèle objet Octavia

| Objet Octavia | Rôle | Équivalent HAProxy |
|---|---|---|
| **Load Balancer** | Entité racine, porte une VIP sur un subnet | La VIP keepalived + le process haproxy |
| **Listener** | Point d'écoute (protocole + port) | Bloc `frontend` |
| **Pool** | Groupe de backends + algorithme de répartition | Bloc `backend` |
| **Member** | Un serveur backend (IP + port + poids) | Ligne `server` dans un `backend` |
| **Health Monitor** | Sonde de santé attachée à un pool | Directive `option httpchk` / `check` |
| **L7 Policy / L7 Rule** | Routage applicatif (host, path, header…) | `acl` + `use_backend` |
| **TLS container (Barbican)** | Certificat + clé stockés dans le secret store | Fichier `.pem` référencé dans `bind` |

### 1.2 Ce que keepalived devient

C'est le point clé de cette migration. Avec HAProxy + keepalived, **vous** gérez la haute disponibilité : deux nœuds, une VIP qui bascule via VRRP, des healthchecks keepalived.

Avec Octavia, **la HA est déléguée au service** :

- La VIP n'est plus une VIP keepalived sur votre réseau L2, mais une **adresse portée par le load balancer Octavia** (un `port` Neutron). Elle peut être interne (subnet privé) ou associée à une **floating IP** pour l'exposition externe.
- La redondance se configure via la **topologie** du load balancer :
  - `SINGLE` : une seule amphora (pas de HA — réservé au dev/test).
  - `ACTIVE_STANDBY` : deux amphorae avec bascule automatique (VRRP géré par Octavia en interne). **C'est l'équivalent direct de votre paire HAProxy+keepalived.**
- Vous ne gérez plus ni VRRP, ni la synchro de conf, ni le `notify_master` : Octavia recrée une amphora défaillante automatiquement.

> **À retenir** : keepalived disparaît de votre périmètre. Choisissez la topologie `ACTIVE_STANDBY` pour conserver le niveau de HA que vous aviez, et provisionnez la floating IP pour reproduire l'adresse publique stable que portait votre VIP.

### 1.3 Algorithmes de répartition

| HAProxy (`balance`) | Octavia (`lb-algorithm`) |
|---|---|
| `roundrobin` | `ROUND_ROBIN` |
| `leastconn` | `LEAST_CONNECTIONS` |
| `source` | `SOURCE_IP` |
| (pondération via `weight`) | `ROUND_ROBIN` + `weight` par member |

---

## 2. Cas d'usage 1 — HTTP basique (L7, sans TLS)

### 2.1 Schéma

```
            VIP / Floating IP :80
                    │
            ┌───────▼────────┐
            │   Listener     │  HTTP:80
            │   Load Balancer│
            └───────┬────────┘
                    │  pool HTTP (round robin)
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   backend1:80  backend2:80  backend3:80
```

Le load balancer écoute en HTTP sur le port 80, voit le contenu applicatif, peut faire du routage L7 et injecter `X-Forwarded-For`. Aucun TLS impliqué.

### 2.2 Configuration HAProxy de départ

```haproxy
frontend http_in
    bind 10.0.0.10:80
    mode http
    option forwardfor
    default_backend web_servers

backend web_servers
    mode http
    balance roundrobin
    option httpchk GET /health
    server web1 10.0.1.11:80 check
    server web2 10.0.1.12:80 check
    server web3 10.0.1.13:80 check
```

### 2.3 Équivalent Octavia — OpenStack CLI

```bash
# 1. Le load balancer (porte la VIP) en HA active/standby
openstack loadbalancer create \
  --name lb-http-basic \
  --vip-subnet-id <SUBNET_ID> \
  --flavor <FLAVOR_ACTIVE_STANDBY> \
  --wait

# 2. Le listener (= frontend)
openstack loadbalancer listener create lb-http-basic \
  --name http-listener \
  --protocol HTTP \
  --protocol-port 80 \
  --wait

# 3. Le pool (= backend) avec insertion de X-Forwarded-For
openstack loadbalancer pool create \
  --name web-pool \
  --listener http-listener \
  --protocol HTTP \
  --lb-algorithm ROUND_ROBIN \
  --wait

# 4. Le health monitor (= option httpchk GET /health)
openstack loadbalancer healthmonitor create web-pool \
  --name web-hm \
  --type HTTP \
  --http-method GET \
  --url-path /health \
  --expected-codes 200 \
  --delay 5 --timeout 3 --max-retries 3 \
  --wait

# 5. Les members (= lignes server)
openstack loadbalancer member create web-pool \
  --address 10.0.1.11 --protocol-port 80 --name web1 --wait
openstack loadbalancer member create web-pool \
  --address 10.0.1.12 --protocol-port 80 --name web2 --wait
openstack loadbalancer member create web-pool \
  --address 10.0.1.13 --protocol-port 80 --name web3 --wait

# 6. (Exposition externe) associer une floating IP à la VIP
openstack floating ip create <EXTERNAL_NET> \
  --port $(openstack loadbalancer show lb-http-basic -f value -c vip_port_id)
```

> **X-Forwarded-For** : en protocole `HTTP`, Octavia insère automatiquement `X-Forwarded-For`, `X-Forwarded-Proto` et `X-Forwarded-Port`. C'est l'équivalent de votre `option forwardfor`. En mode `TCP` (cas 3), ce n'est **pas** possible — voir §4.6.

### 2.4 Équivalent Octavia — Terraform

```hcl
resource "openstack_lb_loadbalancer_v2" "http_basic" {
  name          = "lb-http-basic"
  vip_subnet_id = var.subnet_id
  flavor_id     = var.flavor_active_standby   # topologie ACTIVE_STANDBY
}

resource "openstack_lb_listener_v2" "http" {
  name            = "http-listener"
  protocol        = "HTTP"
  protocol_port   = 80
  loadbalancer_id = openstack_lb_loadbalancer_v2.http_basic.id
}

resource "openstack_lb_pool_v2" "web" {
  name        = "web-pool"
  protocol    = "HTTP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.http.id
}

resource "openstack_lb_monitor_v2" "web" {
  pool_id        = openstack_lb_pool_v2.web.id
  type           = "HTTP"
  http_method    = "GET"
  url_path       = "/health"
  expected_codes = "200"
  delay          = 5
  timeout        = 3
  max_retries    = 3
}

resource "openstack_lb_member_v2" "web" {
  for_each      = { web1 = "10.0.1.11", web2 = "10.0.1.12", web3 = "10.0.1.13" }
  pool_id       = openstack_lb_pool_v2.web.id
  address       = each.value
  protocol_port = 80
  subnet_id     = var.member_subnet_id
}

resource "openstack_networking_floatingip_v2" "vip" {
  pool    = var.external_net_name
  port_id = openstack_lb_loadbalancer_v2.http_basic.vip_port_id
}
```

### 2.5 Équivalent Octavia — API REST (curl)

```bash
TOKEN=$(openstack token issue -f value -c id)
OCTAVIA=https://<endpoint>:9876/v2.0/lbaas

# Load balancer
curl -s -X POST $OCTAVIA/loadbalancers \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"loadbalancer":{"name":"lb-http-basic","vip_subnet_id":"<SUBNET_ID>"}}'

# Listener
curl -s -X POST $OCTAVIA/listeners \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"listener":{"name":"http-listener","protocol":"HTTP","protocol_port":80,"loadbalancer_id":"<LB_ID>"}}'

# Pool
curl -s -X POST $OCTAVIA/pools \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"pool":{"name":"web-pool","protocol":"HTTP","lb_algorithm":"ROUND_ROBIN","listener_id":"<LISTENER_ID>"}}'

# Health monitor
curl -s -X POST $OCTAVIA/healthmonitors \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"healthmonitor":{"pool_id":"<POOL_ID>","type":"HTTP","http_method":"GET","url_path":"/health","expected_codes":"200","delay":5,"timeout":3,"max_retries":3}}'

# Member
curl -s -X POST $OCTAVIA/pools/<POOL_ID>/members \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"member":{"name":"web1","address":"10.0.1.11","protocol_port":80,"subnet_id":"<MEMBER_SUBNET_ID>"}}'
```

---

## 3. Cas d'usage 2 — HTTPS avec terminaison TLS sur le load balancer (offloading)

### 3.1 Schéma

```
   Client  ──HTTPS:443──►  ┌──────────────┐
   (TLS)                    │  Listener    │  TERMINATED_HTTPS:443
                            │  déchiffre   │  (certif dans Barbican)
                            └──────┬───────┘
                                   │  HTTP en clair (réseau interne de confiance)
                       ┌───────────┼───────────┐
                       ▼           ▼           ▼
                  backend1:80  backend2:80  backend3:80
```

Le client parle TLS au load balancer. Octavia **déchiffre** (terminaison), traite le trafic en clair, et le réémet en HTTP vers les backends. C'est l'offloading TLS : les backends ne gèrent aucun certificat.

### 3.2 Configuration HAProxy de départ

```haproxy
frontend https_in
    bind 10.0.0.10:443 ssl crt /etc/haproxy/certs/mon-app.pem
    mode http
    option forwardfor
    http-request set-header X-Forwarded-Proto https
    default_backend web_servers

backend web_servers
    mode http
    balance roundrobin
    option httpchk GET /health
    server web1 10.0.1.11:80 check
    server web2 10.0.1.12:80 check
```

### 3.3 Pré-requis : stocker le certificat dans Barbican

Octavia ne lit pas un `.pem` sur disque ; il référence un **secret PKCS#12** stocké dans Barbican (le secret store d'OpenStack).

```bash
# Construire un PKCS12 à partir de la clé + cert + chaîne
openssl pkcs12 -export \
  -inkey mon-app.key \
  -in mon-app.crt \
  -certfile chaine-ca.crt \
  -passout pass: \
  -out mon-app.p12

# Stocker dans Barbican
openstack secret store \
  --name 'mon-app-tls' \
  --expiration 2027-01-01 \
  -t 'application/octet-stream' \
  -e 'base64' \
  --payload "$(base64 < mon-app.p12)"
# → récupérer le secret href retourné
```

### 3.4 Équivalent Octavia — OpenStack CLI

```bash
openstack loadbalancer create --name lb-https-offload \
  --vip-subnet-id <SUBNET_ID> --flavor <FLAVOR_ACTIVE_STANDBY> --wait

# Listener TERMINATED_HTTPS : la terminaison TLS se fait ici
openstack loadbalancer listener create lb-https-offload \
  --name https-listener \
  --protocol TERMINATED_HTTPS \
  --protocol-port 443 \
  --default-tls-container-ref <SECRET_HREF> \
  --wait

# Pool en HTTP (trafic déchiffré vers les backends)
openstack loadbalancer pool create \
  --name web-pool --listener https-listener \
  --protocol HTTP --lb-algorithm ROUND_ROBIN --wait

openstack loadbalancer healthmonitor create web-pool \
  --type HTTP --http-method GET --url-path /health \
  --expected-codes 200 --delay 5 --timeout 3 --max-retries 3 --wait

openstack loadbalancer member create web-pool \
  --address 10.0.1.11 --protocol-port 80 --name web1 --wait
openstack loadbalancer member create web-pool \
  --address 10.0.1.12 --protocol-port 80 --name web2 --wait
```

> **SNI (plusieurs certificats sur un même listener)** : ajoutez `--sni-container-refs <HREF1> <HREF2> …`. Octavia choisit le certificat selon le SNI présenté, comme le multi-`crt` de HAProxy.
>
> **Redirection HTTP→HTTPS** : créez un second listener HTTP:80 avec une L7 policy `REDIRECT_TO_URL` / `REDIRECT_PREFIX https://…`.

### 3.5 Équivalent Octavia — Terraform

```hcl
resource "openstack_keymanager_secret_v1" "tls" {
  name                     = "mon-app-tls"
  payload                  = filebase64("mon-app.p12")
  payload_content_type     = "application/octet-stream"
  payload_content_encoding = "base64"
  secret_type              = "opaque"
}

resource "openstack_lb_loadbalancer_v2" "https" {
  name          = "lb-https-offload"
  vip_subnet_id = var.subnet_id
  flavor_id     = var.flavor_active_standby
}

resource "openstack_lb_listener_v2" "https" {
  name                      = "https-listener"
  protocol                  = "TERMINATED_HTTPS"
  protocol_port             = 443
  loadbalancer_id           = openstack_lb_loadbalancer_v2.https.id
  default_tls_container_ref = openstack_keymanager_secret_v1.tls.secret_ref
  # sni_container_refs = [ ... ]   # pour du multi-certificat
}

resource "openstack_lb_pool_v2" "web" {
  name        = "web-pool"
  protocol    = "HTTP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.https.id
}

resource "openstack_lb_monitor_v2" "web" {
  pool_id        = openstack_lb_pool_v2.web.id
  type           = "HTTP"
  http_method    = "GET"
  url_path       = "/health"
  expected_codes = "200"
  delay          = 5
  timeout        = 3
  max_retries    = 3
}

resource "openstack_lb_member_v2" "web" {
  for_each      = { web1 = "10.0.1.11", web2 = "10.0.1.12" }
  pool_id       = openstack_lb_pool_v2.web.id
  address       = each.value
  protocol_port = 80
  subnet_id     = var.member_subnet_id
}
```

### 3.6 Équivalent Octavia — API REST (curl)

```bash
# Listener avec terminaison TLS
curl -s -X POST $OCTAVIA/listeners \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"listener":{
        "name":"https-listener",
        "protocol":"TERMINATED_HTTPS",
        "protocol_port":443,
        "loadbalancer_id":"<LB_ID>",
        "default_tls_container_ref":"<SECRET_HREF>"
      }}'

# Pool HTTP en aval
curl -s -X POST $OCTAVIA/pools \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"pool":{"name":"web-pool","protocol":"HTTP","lb_algorithm":"ROUND_ROBIN","listener_id":"<LISTENER_ID>"}}'
```

---

## 4. Cas d'usage 3 — Mode TCP « passthrough » : le backend gère la terminaison TLS

### 4.1 Schéma

```
   Client  ──TLS:443──►  ┌──────────────┐
   (TLS chiffré          │  Listener    │  TCP:443  (n'ouvre PAS le TLS)
    de bout en bout)     │  passthrough │
                         └──────┬───────┘
                                │  flux TLS opaque relayé tel quel
                    ┌───────────┼───────────┐
                    ▼           ▼           ▼
              backend1:443  backend2:443  backend3:443
            (chaque backend porte le certificat et déchiffre)
```

Le load balancer **ne déchiffre rien** : il relaie le flux TCP/TLS brut. La terminaison TLS a lieu sur les backends. Le LB ne voit pas le contenu HTTP, donc pas de routage L7, pas d'injection d'en-têtes. C'est le mode à privilégier pour le TLS de bout en bout, le mTLS, ou les protocoles non-HTTP.

### 4.2 Configuration HAProxy de départ

```haproxy
frontend tls_passthrough
    bind 10.0.0.10:443
    mode tcp
    default_backend secure_servers

backend secure_servers
    mode tcp
    balance roundrobin
    option ssl-hello-chk          # sonde : envoie un ClientHello
    server app1 10.0.1.21:443 check
    server app2 10.0.1.22:443 check
```

### 4.3 Équivalent Octavia — OpenStack CLI

```bash
openstack loadbalancer create --name lb-tcp-passthrough \
  --vip-subnet-id <SUBNET_ID> --flavor <FLAVOR_ACTIVE_STANDBY> --wait

# Listener TCP : aucun certificat, aucune terminaison
openstack loadbalancer listener create lb-tcp-passthrough \
  --name tcp-listener \
  --protocol TCP \
  --protocol-port 443 \
  --wait

# Pool TCP
openstack loadbalancer pool create \
  --name secure-pool --listener tcp-listener \
  --protocol TCP --lb-algorithm ROUND_ROBIN --wait

# Health monitor : TLS-HELLO (équivalent option ssl-hello-chk)
openstack loadbalancer healthmonitor create secure-pool \
  --name secure-hm \
  --type TLS-HELLO \
  --delay 5 --timeout 3 --max-retries 3 \
  --wait

openstack loadbalancer member create secure-pool \
  --address 10.0.1.21 --protocol-port 443 --name app1 --wait
openstack loadbalancer member create secure-pool \
  --address 10.0.1.22 --protocol-port 443 --name app2 --wait
```

> **Health monitor en TCP** : trois options selon le besoin —
> - `TCP` : simple ouverture de connexion (équivalent `check` basique).
> - `TLS-HELLO` : envoie un ClientHello et vérifie la réponse (équivalent `option ssl-hello-chk`). **Recommandé ici** : ça valide que le backend termine bien le TLS.
> - `HTTPS` : nécessite que le LB déchiffre, donc **incompatible** avec le passthrough pur — ne pas utiliser ici.

### 4.4 Équivalent Octavia — Terraform

```hcl
resource "openstack_lb_loadbalancer_v2" "tcp" {
  name          = "lb-tcp-passthrough"
  vip_subnet_id = var.subnet_id
  flavor_id     = var.flavor_active_standby
}

resource "openstack_lb_listener_v2" "tcp" {
  name            = "tcp-listener"
  protocol        = "TCP"
  protocol_port   = 443
  loadbalancer_id = openstack_lb_loadbalancer_v2.tcp.id
}

resource "openstack_lb_pool_v2" "secure" {
  name        = "secure-pool"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.tcp.id
}

resource "openstack_lb_monitor_v2" "secure" {
  pool_id     = openstack_lb_pool_v2.secure.id
  type        = "TLS-HELLO"
  delay       = 5
  timeout     = 3
  max_retries = 3
}

resource "openstack_lb_member_v2" "secure" {
  for_each      = { app1 = "10.0.1.21", app2 = "10.0.1.22" }
  pool_id       = openstack_lb_pool_v2.secure.id
  address       = each.value
  protocol_port = 443
  subnet_id     = var.member_subnet_id
}
```

### 4.5 Équivalent Octavia — API REST (curl)

```bash
curl -s -X POST $OCTAVIA/listeners \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"listener":{"name":"tcp-listener","protocol":"TCP","protocol_port":443,"loadbalancer_id":"<LB_ID>"}}'

curl -s -X POST $OCTAVIA/pools \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"pool":{"name":"secure-pool","protocol":"TCP","lb_algorithm":"ROUND_ROBIN","listener_id":"<LISTENER_ID>"}}'

curl -s -X POST $OCTAVIA/healthmonitors \
  -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"healthmonitor":{"pool_id":"<POOL_ID>","type":"TLS-HELLO","delay":5,"timeout":3,"max_retries":3}}'
```

### 4.6 Conséquence importante : pas de X-Forwarded-For

En mode TCP, le LB ne touche pas au flux applicatif : il ne peut **pas** insérer `X-Forwarded-For`. Le backend ne verra que l'IP de l'amphora, pas celle du client réel. Deux solutions si vous avez besoin de l'IP cliente :

- Activer le **PROXY protocol** : pool en `PROXY` (Octavia ajoute l'en-tête PROXY) **et** backend configuré pour le lire. C'est l'équivalent de `send-proxy` côté HAProxy.
- Sinon, accepter de perdre l'IP cliente (ou la récupérer applicativement, ex. via le SNI/mTLS côté backend).

---

## 5. Tableau de synthèse des 3 cas

| | Cas 1 — HTTP | Cas 2 — HTTPS offload | Cas 3 — TCP passthrough |
|---|---|---|---|
| Protocole **listener** | `HTTP` | `TERMINATED_HTTPS` | `TCP` |
| Protocole **pool** | `HTTP` | `HTTP` | `TCP` |
| Terminaison TLS | aucune | **sur le LB** (Barbican) | **sur le backend** |
| Certificat dans Barbican | non | **oui** | non |
| Routage L7 possible | oui | oui | **non** |
| `X-Forwarded-For` auto | oui | oui | **non** (→ PROXY proto) |
| Health monitor type | `HTTP` | `HTTP` | `TLS-HELLO` ou `TCP` |
| Visibilité du contenu | claire | claire (après déchiffrement) | aucune (opaque) |

---

## 6. Procédure de migration opérationnelle

Le principe directeur : **construire le LB Octavia en parallèle**, le valider hors production, puis basculer le trafic au niveau DNS / floating IP. On ne modifie jamais la paire HAProxy tant que le nouveau chemin n'est pas validé.

### 6.0 Pré-requis

- [ ] Octavia déployé et opérationnel (`openstack loadbalancer provider list` renvoie un provider, ex. `amphora` ou `ovn`).
- [ ] Quota suffisant : chaque LB en `ACTIVE_STANDBY` consomme **2 instances** (amphorae), des ports Neutron et éventuellement des floating IPs.
- [ ] Barbican disponible si cas 2 (terminaison TLS).
- [ ] Security groups : les backends doivent **autoriser le subnet/port des amphorae** sur les ports concernés (80/443). C'est souvent le piège n°1 : un member apparaît `ERROR`/`OFFLINE` parce que le SG bloque l'amphora.
- [ ] Connaître le détail de la VIP keepalived actuelle : adresse, est-elle référencée en DNS ? par une floating IP ? en dur dans des clients ?

### 6.1 Étape 1 — Inventaire de l'existant

Cartographier chaque `frontend`/`backend` du `haproxy.cfg` : port d'écoute, mode (http/tcp), TLS ou non, certificats, healthchecks, algorithme, persistance de session (`cookie`/`stick-table`), ACL L7. Chaque frontend devient un listener, chaque backend un pool.

> **Persistance de session** : si vous aviez `cookie SERVERID insert` (HTTP) ou `stick on src` (TCP), reportez-le via `--session-persistence type=APP_COOKIE,cookie_name=…` (ou `HTTP_COOKIE`, `SOURCE_IP`) sur le pool Octavia.

### 6.2 Étape 2 — Construire le LB Octavia en parallèle

Provisionner le load balancer, listeners, pools, monitors et members selon le cas d'usage (§2–4), de préférence en **Terraform** pour la reproductibilité. À ce stade :

- La VIP Octavia est **différente** de la VIP keepalived (nouvelle adresse, nouvelle floating IP de test).
- La production continue de passer par HAProxy. Aucun impact.

### 6.3 Étape 3 — Valider hors production

```bash
# État global : doit être ACTIVE / ONLINE
openstack loadbalancer show lb-https-offload -c provisioning_status -c operating_status

# Santé des members : operating_status doit passer à ONLINE
openstack loadbalancer member list web-pool

# Test fonctionnel direct sur la VIP de test (sans toucher au DNS prod)
curl -kv https://<VIP_OCTAVIA_TEST>/health
```

Vérifier explicitement : codes HTTP, certificat servi (cas 2), bon backend atteint, en-têtes `X-Forwarded-*` reçus côté appli (cas 1 & 2), et que les members basculent bien `OFFLINE` quand on arrête un backend.

### 6.4 Étape 4 — Bascule du trafic

Choisir **une** stratégie selon votre point d'entrée :

- **Bascule DNS** (recommandé) : si vos clients passent par un nom DNS, baissez le **TTL** à 60s 24–48h avant, puis repointez l'enregistrement vers la floating IP du LB Octavia. Rollback = repointer vers l'ancienne VIP.
- **Réassignation de floating IP** : si la VIP publique est une floating IP, détachez-la des nœuds HAProxy et **rattachez-la au `vip_port_id` du LB Octavia**. Bascule quasi instantanée, IP inchangée.
  ```bash
  openstack floating ip unset <FIP>          # détache de l'ancien port
  openstack floating ip set --port \
    $(openstack loadbalancer show lb-https-offload -f value -c vip_port_id) <FIP>
  ```
- Faites la bascule en heures creuses, surveillez les logs applicatifs et le `operating_status` du LB en continu.

### 6.5 Étape 5 — Décommissionnement HAProxy + keepalived

Uniquement **après une période d'observation** (24–72h selon criticité) :

1. Arrêter keepalived sur les deux nœuds (la VIP keepalived doit déjà être inutilisée).
2. Arrêter et désactiver le service haproxy.
3. Libérer l'ancienne VIP / floating IP si elle n'a pas été réutilisée.
4. Archiver les `haproxy.cfg` et `keepalived.conf` (traçabilité / rollback).
5. Déprovisionner les VM HAProxy.

### 6.6 Plan de rollback

Tant que HAProxy n'est pas décommissionné, le rollback est trivial et rapide :

| Stratégie de bascule | Rollback |
|---|---|
| DNS | Repointer l'enregistrement vers l'ancienne VIP keepalived (effet sous 1×TTL). |
| Floating IP | Détacher la FIP du `vip_port_id` Octavia, la rattacher aux nœuds HAProxy. |

Garder keepalived + haproxy **démarrés mais hors trafic** pendant toute la phase d'observation : c'est votre filet de sécurité immédiat.

---

## 7. Checklist de migration

```
PRÉPARATION
[ ] Octavia opérationnel + provider vérifié
[ ] Quota instances/ports/FIP validé (×2 par LB en ACTIVE_STANDBY)
[ ] Inventaire haproxy.cfg → listeners/pools mappés
[ ] Persistance de session identifiée et reportée
[ ] (Cas 2) Certificats convertis en PKCS12 et stockés dans Barbican
[ ] Security groups backends ouverts au subnet des amphorae

CONSTRUCTION
[ ] LB créé en ACTIVE_STANDBY (HA équivalente à keepalived)
[ ] Listeners créés (HTTP / TERMINATED_HTTPS / TCP selon le cas)
[ ] Pools + algorithme + persistance
[ ] Health monitors (HTTP / TLS-HELLO / TCP)
[ ] Members ajoutés
[ ] (Cas 3) PROXY protocol si IP cliente nécessaire

VALIDATION
[ ] provisioning_status = ACTIVE, operating_status = ONLINE
[ ] Tous les members ONLINE
[ ] Test curl sur VIP de test OK (codes, certif, backend, en-têtes)
[ ] Test de panne d'un backend → bascule correcte

BASCULE
[ ] TTL DNS abaissé 24–48h avant (si bascule DNS)
[ ] Bascule DNS ou réassignation FIP en heures creuses
[ ] Surveillance logs + operating_status post-bascule

DÉCOMMISSIONNEMENT
[ ] Observation 24–72h, HAProxy gardé hors trafic (rollback)
[ ] keepalived arrêté/désactivé
[ ] haproxy arrêté/désactivé
[ ] Confs archivées, VM déprovisionnées
```

---

## 8. Pièges fréquents

- **Members OFFLINE / ERROR** : presque toujours un security group qui bloque l'amphora, ou un health monitor mal calibré (path inexistant, code attendu faux). Vérifiez d'abord le SG, puis le monitor.
- **`TERMINATED_HTTPS` refusé** : le provider `ovn` ne fait pas de terminaison TLS — il faut le provider `amphora`. Vérifiez `openstack loadbalancer provider list`.
- **Certificat non pris en compte** : le PKCS12 doit contenir la **chaîne complète** (cert + intermédiaires) ; un secret Barbican mal encodé donne un listener qui ne démarre pas.
- **Perte de l'IP cliente en cas 3** : attendue en TCP — basculez le pool en `PROXY` et configurez le backend pour lire l'en-tête PROXY.
- **HTTP→HTTPS** : pas automatique, à recréer via un listener HTTP:80 + L7 policy de redirection.
- **Quota épuisé** : `ACTIVE_STANDBY` double la consommation d'instances ; un LB qui reste `PENDING_CREATE` est souvent un problème de quota Nova.
- **Pas de hot-reload comme HAProxy** : modifier un listener déclenche une reconfiguration de l'amphora ; les changements sont rapides mais non instantanés — évitez les modifications en rafale pendant un pic.
