# ============================================================
# Load Balancer Octavia
# ============================================================
variable "lb_name" {
  description = "Nom logique du load balancer Octavia."
  type        = string
  default     = "openbao-lb"
}

variable "lb_description" {
  description = "Description du load balancer (visible dans l'API Octavia)."
  type        = string
  default     = "OpenBao HA — frontal Octavia ACTIVE_STANDBY (TCP passthrough 8200)"
}

variable "lb_flavor_id" {
  description = <<-EOT
    UUID d'une flavor Octavia avec topology=ACTIVE_STANDBY.
    Laisser null pour utiliser la flavor par défaut du tenant — auquel cas
    il faut vérifier que celle-ci est bien ACTIVE_STANDBY :
      openstack loadbalancer flavor list
      openstack loadbalancer flavorprofile show <profile_id>
    Si la flavor par défaut est SINGLE, fournir un UUID explicite ici.
  EOT
  type        = string
  default     = null
}

variable "lb_availability_zone" {
  description = "AZ Octavia pour le LB (laisser null pour 'any')."
  type        = string
  default     = null
}

variable "vip_subnet_id" {
  description = "UUID du subnet Neutron sur lequel Octavia pose la VIP du LB."
  type        = string
}

variable "vip_address" {
  description = "Adresse IP statique à imposer pour la VIP du LB (null = auto-attribuée par Neutron)."
  type        = string
  default     = null
}

# ============================================================
# Listener TCP:8200
# ============================================================
variable "listener_port" {
  description = "Port TCP exposé par le listener (port API OpenBao)."
  type        = number
  default     = 8200
}

variable "listener_connection_limit" {
  description = "Limite de connexions concurrentes sur le listener (-1 = illimité)."
  type        = number
  default     = -1
}

variable "listener_timeout_client_data_ms" {
  description = "Timeout client (inactivité), en millisecondes. Iso HAProxy timeout client 2m."
  type        = number
  default     = 120000
}

variable "listener_timeout_member_data_ms" {
  description = "Timeout membre (inactivité), en millisecondes. Iso HAProxy timeout server 2m."
  type        = number
  default     = 120000
}

variable "listener_timeout_member_connect_ms" {
  description = "Timeout de connexion vers les membres, en millisecondes. Iso HAProxy timeout connect 5s."
  type        = number
  default     = 5000
}

# ============================================================
# Pool + membres
# ============================================================
variable "members_subnet_id" {
  description = "UUID du subnet Neutron où vivent les nœuds OpenBao (utilisé par les members)."
  type        = string
}

variable "openbao_nodes" {
  description = "Liste des nœuds OpenBao à inscrire dans le pool. Adresses dans members_subnet_id."
  type = list(object({
    name    = string
    address = string
  }))

  validation {
    condition     = length(var.openbao_nodes) >= 1
    error_message = "Il faut au moins un nœud OpenBao dans le pool."
  }
}

variable "member_port" {
  description = "Port d'écoute des nœuds OpenBao (API)."
  type        = number
  default     = 8200
}

# ============================================================
# Health monitor — iso HAProxy actuel
# ============================================================
variable "health_check_path" {
  description = "Chemin HTTP du healthcheck OpenBao."
  type        = string
  default     = "/v1/sys/health?standbyok=true&perfstandbyok=true"
}

variable "health_check_expected_codes" {
  description = <<-EOT
    Codes HTTP acceptés par le healthcheck :
      200 = leader actif
      429 = standby unsealed (sert lectures)
    Tout autre code marque le membre DOWN.
  EOT
  type    = string
  default = "200,429"
}

variable "health_check_delay" {
  description = "Intervalle entre healthchecks (secondes)."
  type        = number
  default     = 5
}

variable "health_check_timeout" {
  description = "Timeout d'un healthcheck individuel (secondes). Doit être < delay."
  type        = number
  default     = 3
}

variable "health_check_max_retries" {
  description = "Nb de healthchecks OK consécutifs pour repasser un membre UP."
  type        = number
  default     = 2
}

variable "health_check_max_retries_down" {
  description = "Nb de healthchecks KO consécutifs pour marquer un membre DOWN."
  type        = number
  default     = 3
}

# ============================================================
# Floating IP (préallouée, partagée avec le DNS vip-bao.intra)
# ============================================================
variable "floating_ip_address" {
  description = <<-EOT
    Adresse de la Floating IP déjà allouée (ex. "10.10.0.100").
    Doit exister dans le projet — sera lue par data.openstack_networking_floatingip_v2
    et associée au port VIP du LB par openstack_networking_floatingip_associate_v2.
  EOT
  type    = string
}

# ============================================================
# Tags Octavia (utiles pour l'inventaire / facturation interne)
# ============================================================
variable "tags" {
  description = "Tags Octavia posés sur le LB."
  type        = list(string)
  default     = ["openbao", "ha", "managed-by-terraform"]
}
