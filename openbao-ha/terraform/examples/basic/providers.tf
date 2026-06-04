# Authentification OpenStack via clouds.yaml.
# Le fichier clouds.yaml doit contenir un cloud nommé comme var.openstack_cloud
# (par défaut "openbao") avec les credentials et un rôle Keystone permettant
# au minimum "load-balancer_member" sur le projet cible.
#
# Exemple clouds.yaml :
#   clouds:
#     openbao:
#       auth:
#         auth_url: https://keystone.example.org:5000/v3
#         username: openbao-tf
#         password: ...
#         project_name: openbao-prod
#         project_domain_name: Default
#         user_domain_name: Default
#       region_name: RegionOne
#       interface: public
#       identity_api_version: 3

provider "openstack" {
  cloud = var.openstack_cloud
}

variable "openstack_cloud" {
  description = "Nom du cloud dans clouds.yaml utilisé pour s'authentifier."
  type        = string
  default     = "openbao"
}
