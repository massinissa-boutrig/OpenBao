# ============================================================
# Load Balancer Octavia (topologie ACTIVE_STANDBY via la flavor)
# ============================================================
resource "openstack_lb_loadbalancer_v2" "openbao" {
  name              = var.lb_name
  description       = var.lb_description
  vip_subnet_id     = var.vip_subnet_id
  vip_address       = var.vip_address
  flavor_id         = var.lb_flavor_id
  availability_zone = var.lb_availability_zone
  loadbalancer_provider = "amphora"
  admin_state_up    = true
  tags              = var.tags
}

# ============================================================
# Listener TCP — port API OpenBao (passthrough, TLS terminé par OpenBao)
# ============================================================
resource "openstack_lb_listener_v2" "openbao_8200" {
  name                       = "${var.lb_name}-listener-tcp-${var.listener_port}"
  description                = "Listener TCP passthrough vers les nœuds OpenBao"
  loadbalancer_id            = openstack_lb_loadbalancer_v2.openbao.id
  protocol                   = "TCP"
  protocol_port              = var.listener_port
  connection_limit           = var.listener_connection_limit
  timeout_client_data        = var.listener_timeout_client_data_ms
  timeout_member_data        = var.listener_timeout_member_data_ms
  timeout_member_connect     = var.listener_timeout_member_connect_ms
  admin_state_up             = true
  tags                       = var.tags
}

# ============================================================
# Pool — ROUND_ROBIN sans stickiness (OpenBao redirige les writes
# vers le leader nativement, pas besoin de session persistence).
# ============================================================
resource "openstack_lb_pool_v2" "openbao" {
  name            = "${var.lb_name}-pool"
  description     = "Pool des 3 nœuds OpenBao (Raft)"
  listener_id     = openstack_lb_listener_v2.openbao_8200.id
  protocol        = "TCP"
  lb_method       = "ROUND_ROBIN"
  admin_state_up  = true
  tags            = var.tags
}

# ============================================================
# Health monitor — HTTPS GET /v1/sys/health
# Codes acceptés : 200 (leader) ou 429 (standby unsealed).
# ============================================================
resource "openstack_lb_monitor_v2" "openbao_health" {
  name             = "${var.lb_name}-monitor"
  pool_id          = openstack_lb_pool_v2.openbao.id
  type             = "HTTPS"
  http_method      = "GET"
  url_path         = var.health_check_path
  expected_codes   = var.health_check_expected_codes
  delay            = var.health_check_delay
  timeout          = var.health_check_timeout
  max_retries      = var.health_check_max_retries
  max_retries_down = var.health_check_max_retries_down
  admin_state_up   = true
}

# ============================================================
# Floating IP — on récupère la FIP déjà allouée par son adresse et
# on l'associe au port VIP du LB. Le DNS vip-bao.intra pointe déjà
# sur cette FIP, donc la migration est transparente côté clients
# une fois l'association faite.
# ============================================================
data "openstack_networking_floatingip_v2" "openbao" {
  address = var.floating_ip_address
}

resource "openstack_networking_floatingip_associate_v2" "openbao" {
  floating_ip = data.openstack_networking_floatingip_v2.openbao.address
  port_id     = openstack_lb_loadbalancer_v2.openbao.vip_port_id

  # On attend explicitement que le LB soit ACTIVE avant d'attacher la FIP,
  # sinon Neutron peut renvoyer un 409 si le port VIP est encore en build.
  depends_on = [
    openstack_lb_loadbalancer_v2.openbao,
    openstack_lb_listener_v2.openbao_8200,
  ]
}
