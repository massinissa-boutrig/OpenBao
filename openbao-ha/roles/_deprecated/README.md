# Rôles dépréciés

Ces rôles ne sont plus référencés par `playbooks/site.yml` et ne sont pas exécutés.

Ils sont conservés ici **uniquement à des fins de rollback** vers l'ancienne architecture HAProxy + keepalived + Floating IP failover par script, dans le cas où la migration vers Octavia (LBaaS OpenStack) poserait un problème non détecté pendant les tests.

| Rôle | Remplacement |
|---|---|
| `haproxy/` | Load balancer Octavia (`terraform/octavia-lb/`) |
| `keepalived/` | Topologie `ACTIVE_STANDBY` Octavia (VRRP géré par les amphorae) |
| `openstack_fip/` | Association FIP → port VIP du LB Octavia (Terraform, statique) |

**À supprimer définitivement** une fois la migration validée en production et l'expérience d'exploitation Octavia jugée satisfaisante (typiquement 1 à 3 mois).

Voir `docs/PLAN-MIGRATION-OCTAVIA.md` pour la procédure complète.
