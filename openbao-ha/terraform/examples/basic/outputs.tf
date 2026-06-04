output "endpoint_url" {
  description = "URL publique de l'API OpenBao."
  value       = module.octavia_lb.endpoint_url
}

output "lb_id" {
  description = "UUID du load balancer Octavia."
  value       = module.octavia_lb.lb_id
}

output "lb_vip_address" {
  description = "Adresse IP interne de la VIP du LB."
  value       = module.octavia_lb.lb_vip_address
}

output "member_ids" {
  description = "Map nom de nœud → UUID du membre dans le pool."
  value       = module.octavia_lb.member_ids
}
