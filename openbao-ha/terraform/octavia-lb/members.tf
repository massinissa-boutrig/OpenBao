# ============================================================
# Members — un par nœud OpenBao.
# Le subnet_id permet à Octavia de router correctement le trafic
# (les amphorae sont sur vip_subnet_id, les nœuds sur members_subnet_id).
# ============================================================
resource "openstack_lb_member_v2" "bao_node" {
  for_each = { for node in var.openbao_nodes : node.name => node }

  name           = each.value.name
  pool_id        = openstack_lb_pool_v2.openbao.id
  address        = each.value.address
  protocol_port  = var.member_port
  subnet_id      = var.members_subnet_id
  weight         = 1
  admin_state_up = true

  # Sérialise la création des members : Octavia met le LB en
  # PENDING_UPDATE pendant chaque ajout, créer en parallèle déclenche
  # des "Load Balancer ... is immutable and cannot be updated".
  depends_on = [
    openstack_lb_monitor_v2.openbao_health,
  ]
}
