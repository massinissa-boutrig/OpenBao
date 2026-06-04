variable "vip_subnet_id" {
  description = "UUID du subnet Neutron sur lequel Octavia pose la VIP du LB."
  type        = string
}

variable "members_subnet_id" {
  description = "UUID du subnet Neutron où vivent les nœuds OpenBao."
  type        = string
}

variable "floating_ip_address" {
  description = "Adresse de la Floating IP préallouée (pointée par le DNS vip-bao.intra)."
  type        = string
}

variable "vip_address" {
  description = "IP statique imposée pour la VIP du LB (null = auto)."
  type        = string
  default     = null
}

variable "lb_flavor_id" {
  description = "UUID d'une flavor Octavia ACTIVE_STANDBY (null = flavor par défaut du tenant)."
  type        = string
  default     = null
}

variable "lb_availability_zone" {
  description = "AZ Octavia pour le LB (null = 'any')."
  type        = string
  default     = null
}

variable "openbao_nodes" {
  description = "Liste des nœuds OpenBao à inscrire dans le pool."
  type = list(object({
    name    = string
    address = string
  }))
}
