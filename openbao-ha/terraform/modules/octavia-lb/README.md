# Module `octavia-lb`

Provisionne le frontal Octavia (load balancer ACTIVE_STANDBY) pour un cluster
OpenBao HA : load balancer, listener TCP passthrough sur 8200, pool ROUND_ROBIN,
health monitor HTTPS sur `/v1/sys/health`, membres (un par nœud), et association
d'une Floating IP préallouée au port VIP.

Le module ne déclare **aucun provider** : la configuration appelante doit
instancier le provider `openstack` (authentification via `clouds.yaml`).

## Utilisation

```hcl
provider "openstack" {
  cloud = "openbao"
}

module "octavia_lb" {
  source = "../../modules/octavia-lb"

  vip_subnet_id       = "11111111-1111-1111-1111-111111111111"
  members_subnet_id   = "22222222-2222-2222-2222-222222222222"
  floating_ip_address = "10.10.0.100"

  openbao_nodes = [
    { name = "bao-01", address = "10.20.0.11" },
    { name = "bao-02", address = "10.20.0.12" },
    { name = "bao-03", address = "10.20.0.13" },
  ]
}
```

## Entrées principales

| Variable | Type | Requis | Défaut |
|---|---|---|---|
| `vip_subnet_id` | string | oui | — |
| `members_subnet_id` | string | oui | — |
| `floating_ip_address` | string | oui | — |
| `openbao_nodes` | list(object{name,address}) | oui | — |
| `lb_name` | string | non | `openbao-lb` |
| `lb_flavor_id` | string | non | `null` (flavor par défaut — vérifier qu'elle est ACTIVE_STANDBY) |
| `vip_address` | string | non | `null` (auto) |
| `listener_port` / `member_port` | number | non | `8200` |
| `health_check_path` | string | non | `/v1/sys/health?standbyok=true&perfstandbyok=true` |
| `health_check_expected_codes` | string | non | `200,429` |
| `tags` | list(string) | non | `["openbao","ha","managed-by-terraform"]` |

Voir `variables.tf` pour la liste complète (timeouts, paramètres du health monitor, etc.).

## Sorties

`lb_id`, `lb_vip_address`, `lb_vip_port_id`, `listener_id`, `pool_id`,
`monitor_id`, `member_ids`, `floating_ip_address`, `endpoint_url`.
