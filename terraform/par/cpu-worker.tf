########################################
# CPU worker
#
# Billed per use. Created the first time scripts/par/cpu-up.sh runs, powered
# off by scripts/par/cpu-down.sh between uses and powered back on by cpu-up.sh,
# so the use case lanes keep their volumes without paying for an idle 8 vCPU.
# scripts/par/cpu-destroy.sh removes it at the end of the project.
#
# cpu_worker_enabled defaults to false so that a bare terraform apply never
# creates it by accident.
########################################

resource "scaleway_instance_ip" "cpu_worker" {
  count = var.cpu_worker_enabled ? 1 : 0
  zone  = local.cpu_zone

  type = "routed_ipv4"
  tags = local.tags
}

resource "scaleway_ipam_ip" "cpu_worker" {
  count = var.cpu_worker_enabled ? 1 : 0

  address = var.cpu_worker_private_ip
  tags    = local.tags

  source {
    private_network_id = scaleway_vpc_private_network.main.id
  }
}

# Security groups filter the public interface only. SSH from admin ranges; the
# cross-site metrics rule is added here if use case 6 puts its endpoint on this
# node.
resource "scaleway_instance_security_group" "cpu_worker" {
  count = var.cpu_worker_enabled ? 1 : 0
  zone  = local.cpu_zone

  name                    = "${var.cluster_name}-cpu"
  description             = "CPU worker: SSH from admin ranges"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
  tags                    = local.tags

  dynamic "inbound_rule" {
    for_each = var.admin_cidrs
    content {
      action   = "accept"
      protocol = "TCP"
      port     = 22
      ip_range = inbound_rule.value
    }
  }

  dynamic "inbound_rule" {
    for_each = local.public_mode ? [scaleway_instance_ip.control_plane.address] : []
    content {
      action   = "accept"
      protocol = "ANY"
      ip_range = "${inbound_rule.value}/32"
    }
  }
}

resource "scaleway_instance_server" "cpu_worker" {
  count = var.cpu_worker_enabled ? 1 : 0
  zone  = local.cpu_zone

  name              = local.cpu_worker_name
  type              = var.cpu_worker_type
  image             = var.cpu_worker_image
  security_group_id = scaleway_instance_security_group.cpu_worker[0].id
  ip_id             = scaleway_instance_ip.cpu_worker[0].id
  tags              = concat(local.tags, ["cpu-worker"])

  # started or stopped. Stopped is Scaleway's power-off: compute billing stops,
  # the disk and the IP stay and keep billing.
  state = var.cpu_worker_running ? "started" : "stopped"

  root_volume {
    size_in_gb            = var.cpu_worker_root_volume_size_gb
    volume_type           = var.root_volume_type
    delete_on_termination = true
  }

  user_data = {
    cloud-init = templatefile("${path.module}/cloud-init/cpu-worker.sh.tftpl", {
      common = templatefile("${path.module}/cloud-init/common.sh.tftpl", merge(local.common_bootstrap, {
        node_name            = local.cpu_worker_name
        node_ip              = local.cpu_worker_node_ip
        private_ip           = var.cpu_worker_private_ip
        private_prefix       = split("/", var.private_network_subnet)[1]
        private_nic_required = !local.public_mode
      }))
    })
  }

  lifecycle {
    # The bootstrap only runs on first boot, and the worker lives for the whole
    # project. A rendering change must not rebuild it and take the lanes'
    # volumes with it. Change the script deliberately, then taint and replace.
    ignore_changes = [user_data]
  }

  depends_on = [scaleway_iam_ssh_key.admin]
}

resource "scaleway_instance_private_nic" "cpu_worker" {
  count = var.cpu_worker_enabled ? 1 : 0
  zone  = local.cpu_zone

  server_id          = scaleway_instance_server.cpu_worker[0].id
  private_network_id = scaleway_vpc_private_network.main.id
  ipam_ip_ids        = [scaleway_ipam_ip.cpu_worker[0].id]
  tags               = local.tags

  depends_on = [scaleway_ipam_ip.cpu_worker]
}
