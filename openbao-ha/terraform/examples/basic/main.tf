# ============================================================
# Exemple d'appel du module octavia-lb pour OpenBao HA.
# Renseigner les valeurs réelles dans terraform.tfvars
# (voir terraform.tfvars.example).
# ============================================================
module "octavia_lb" {
  source = "../../modules/octavia-lb"

  # Réseau
  vip_subnet_id       = var.vip_subnet_id
  members_subnet_id   = var.members_subnet_id
  floating_ip_address = var.floating_ip_address
  vip_address         = var.vip_address

  # Flavor Octavia ACTIVE_STANDBY (null = flavor par défaut du tenant)
  lb_flavor_id         = var.lb_flavor_id
  lb_availability_zone = var.lb_availability_zone

  # Nœuds OpenBao du cluster Raft
  openbao_nodes = var.openbao_nodes
}
