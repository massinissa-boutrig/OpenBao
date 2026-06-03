# Contraintes de provider du module.
# Pas de required_version ni de bloc provider ici : c'est la
# configuration racine appelante qui fixe la version de Terraform
# et instancie le provider openstack (auth via clouds.yaml).
terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">= 3.0.0, < 4.0.0"
    }
  }
}
