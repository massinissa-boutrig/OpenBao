output "lb_id" {
  description = "UUID du load balancer Octavia. Utile pour `openstack loadbalancer status show <id>`."
  value       = openstack_lb_loadbalancer_v2.openbao.id
}

output "lb_vip_address" {
  description = "Adresse IP interne de la VIP du LB (sur vip_subnet_id). Sert pour tests directs et règles nftables des nœuds OpenBao."
  value       = openstack_lb_loadbalancer_v2.openbao.vip_address
}

output "lb_vip_port_id" {
  description = "UUID du port Neutron portant la VIP du LB."
  value       = openstack_lb_loadbalancer_v2.openbao.vip_port_id
}

output "listener_id" {
  description = "UUID du listener TCP."
  value       = openstack_lb_listener_v2.openbao_8200.id
}

output "pool_id" {
  description = "UUID du pool."
  value       = openstack_lb_pool_v2.openbao.id
}

output "monitor_id" {
  description = "UUID du health monitor."
  value       = openstack_lb_monitor_v2.openbao_health.id
}

output "member_ids" {
  description = "Map nom de nœud → UUID du membre dans le pool."
  value       = { for k, m in openstack_lb_member_v2.bao_node : k => m.id }
}

output "floating_ip_address" {
  description = "Floating IP désormais associée au port VIP du LB (pointée par le DNS vip-bao.intra)."
  value       = data.openstack_networking_floatingip_v2.openbao.address
}

output "endpoint_url" {
  description = "URL publique de l'API OpenBao (à utiliser dans les clients)."
  value       = "https://${data.openstack_networking_floatingip_v2.openbao.address}:${var.listener_port}"
}
