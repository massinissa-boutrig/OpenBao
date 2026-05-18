# Module Terraform — Octavia LB pour OpenBao HA

Provisionne le load balancer Octavia (LBaaS OpenStack) qui remplace la paire HAProxy + keepalived/FIP-failover de l'ancienne architecture.

---

## Topologie créée

```
                   Clients
                     │  HTTPS:8200
                     ▼
            Floating IP Neutron
                     │  (associée au port VIP du LB)
                     ▼
      Octavia LB — ACTIVE_STANDBY
       (2 amphorae VRRP, bascule <5s)
                     │  TCP:8200 passthrough
        ┌────────────┼────────────┐
        ▼            ▼            ▼
   bao-node-1   bao-node-2   bao-node-3
     (AZ-1)       (AZ-2)       (AZ-3)
```

Le TLS reste terminé par OpenBao (pas par le LB) : iso-fonctionnel avec l'ancien HAProxy en mode TCP passthrough.

---

## Ressources créées

| Ressource | Rôle |
|---|---|
| `openstack_lb_loadbalancer_v2.openbao` | LB Octavia (amphora, ACTIVE_STANDBY via flavor) |
| `openstack_lb_listener_v2.openbao_8200` | Listener TCP:8200 |
| `openstack_lb_pool_v2.openbao` | Pool ROUND_ROBIN |
| `openstack_lb_member_v2.bao_node["bao-node-N"]` | 3 membres |
| `openstack_lb_monitor_v2.openbao_health` | Health monitor HTTPS `/v1/sys/health` (200, 429) |
| `openstack_networking_floatingip_associate_v2.openbao` | Associe la FIP préallouée au port VIP du LB |

---

## Prérequis

1. **Octavia disponible** sur le tenant. Vérifier :
   ```bash
   openstack catalog show load-balancer
   openstack loadbalancer flavor list
   ```
2. **Flavor ACTIVE_STANDBY** identifiée. Si la flavor par défaut est `SINGLE`, créer/utiliser une flavor avec `loadbalancer_topology = ACTIVE_STANDBY` et passer son UUID dans `lb_flavor_id`.
3. **Compte Keystone** avec le rôle `load-balancer_member` (au minimum) sur le projet cible. Ajouter un cloud `openbao` dans `~/.config/openstack/clouds.yaml`.
4. **Subnets Neutron** existants :
   - `vip_subnet_id` : subnet sur lequel Octavia pose la VIP du LB
   - `members_subnet_id` : subnet où vivent les 3 VMs OpenBao
5. **Floating IP préallouée** (celle référencée dans le DNS `vip-bao.intra`). Ne pas en recréer une — passer son adresse dans `floating_ip_address`.

---

## Utilisation

```bash
cd terraform/octavia-lb
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # remplir les UUIDs et la FIP

terraform init
terraform plan
terraform apply
```

À l'issue, `terraform output endpoint_url` donne l'URL publique de l'API OpenBao.

### Tests post-déploiement

```bash
# Test direct sur la VIP interne (sans passer par la FIP) :
curl -k --resolve vip-bao.intra:8200:$(terraform output -raw lb_vip_address) \
  https://vip-bao.intra:8200/v1/sys/health

# Test via la FIP (= ce que voient les clients) :
curl -k https://$(terraform output -raw floating_ip_address):8200/v1/sys/health

# État détaillé du LB :
openstack loadbalancer status show $(terraform output -raw lb_id)
```

Tous les membres doivent ressortir avec `operating_status: ONLINE`.

---

## Procédure de migration (depuis HAProxy/keepalived/FIP-script existants)

Migration sans coupure : on précâble le LB en parallèle, on teste sur l'IP interne, puis on déplace la FIP.

1. **Apply Terraform initial** sans la FIP : commenter la ressource `openstack_networking_floatingip_associate_v2.openbao` ou utiliser `terraform apply -target='openstack_lb_loadbalancer_v2.openbao' …`
2. **Pré-câbler nftables** sur les 3 nœuds OpenBao : ajouter le CIDR du `vip_subnet_id` aux sources autorisées sur le port 8200 (variable `octavia_lb_subnet_cidr` dans `inventories/production/group_vars/all/main.yml`, puis `ansible-playbook playbooks/site.yml --tags firewall`). À ce stade les 3 nœuds acceptent **et** l'ancien HAProxy **et** Octavia.
3. **Test fonctionnel** depuis l'IP interne du LB (`lb_vip_address`) : healthcheck, login bao, read d'un secret.
4. **Apply Terraform complet** avec la FIP : la FIP migre de ha-1 vers le port VIP du LB. Coupure observée : 1 à 5 secondes.
5. **Valider** via le DNS `vip-bao.intra`.
6. **Arrêter HAProxy** : `ansible -i inventories/production haproxy -m systemd -a "name=haproxy state=stopped enabled=no"`. Garder les VMs ha-1/ha-2 allumées 24-48h en sécurité, puis les détruire.
7. **Nettoyer Ansible** : retirer le groupe `haproxy` de l'inventaire, retirer les rôles `haproxy/`, `keepalived/`, `openstack_fip/`.

### Rollback express

Si problème pendant la fenêtre :

```bash
# Réassocier la FIP au port de ha-1 directement par Neutron (Terraform sera resynchronisé après) :
openstack floating ip set --port <PORT_ID_HA1> $(terraform output -raw floating_ip_address)
```

Les HAProxy étant restés actifs jusqu'à l'étape 6, le service repart en quelques secondes.

---

## Variables principales

Voir `variables.tf` pour le détail. Les variables sans `default` sont obligatoires.

| Variable | Défaut | Notes |
|---|---|---|
| `openstack_cloud` | `"openbao"` | Cloud dans clouds.yaml |
| `lb_name` | `"openbao-lb"` | |
| `lb_flavor_id` | `null` | UUID de la flavor ACTIVE_STANDBY (si différent du défaut tenant) |
| `vip_subnet_id` | — | Obligatoire |
| `members_subnet_id` | — | Obligatoire |
| `openbao_nodes` | — | Obligatoire — liste `[{name, address}]` |
| `floating_ip_address` | — | Obligatoire — IP de la FIP préallouée |
| `listener_port` | `8200` | |
| `health_check_path` | `/v1/sys/health?standbyok=true&perfstandbyok=true` | Iso HAProxy |
| `health_check_expected_codes` | `"200,429"` | Iso HAProxy |

---

## Limitations connues

- **Flavor ACTIVE_STANDBY non créable via ce module** : la création d'une flavor Octavia (`openstack_lb_flavor_v2`) demande des droits admin sur Octavia. C'est fait par l'équipe OpenStack, pas par le tenant OpenBao. Le module se contente de la *consommer* via `lb_flavor_id`.
- **Pas d'auto-création de la FIP** : volontaire, on réutilise la FIP existante référencée dans le DNS pour ne pas casser les clients en place. Si on veut une nouvelle FIP, l'ajouter en dehors de ce module ou créer une `openstack_networking_floatingip_v2` dédiée.
- **`vip_address` fixe optionnel** : si l'IP de la VIP interne doit être stable (parce qu'utilisée dans des règles nftables ou DNS internes), la fixer dans tfvars. Sinon Neutron en choisit une dans `vip_subnet_id`.

---

## Voir aussi

- Plan de migration complet : [`../../docs/PLAN-MIGRATION-OCTAVIA.md`](../../docs/PLAN-MIGRATION-OCTAVIA.md)
- README projet : [`../../README.md`](../../README.md)
- Documentation Octavia : <https://docs.openstack.org/octavia/latest/>
- Provider Terraform OpenStack : <https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs>
