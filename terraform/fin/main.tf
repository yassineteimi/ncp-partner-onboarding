locals {
  cp_name  = "${var.cluster_name}-cp-01"
  gpu_name = "${var.cluster_name}-gpu-01"

  # The SSH key and the startup scripts exist only while a node does, so that
  # between windows nothing of this site is left at Verda.
  any_enabled = var.cp_enabled || var.gpu_enabled

  # The shared bootstrap block from par, rendered for a site with no private
  # network and no node address known before the node exists. The private
  # network values are unused here but must be defined for the template.
  common_bootstrap = {
    kubernetes_minor           = var.kubernetes_minor
    kubernetes_package_version = var.kubernetes_package_version
    containerd_package_version = var.containerd_package_version
    private_network            = false
    node_ip                    = ""
    private_ip                 = ""
    private_prefix             = ""
    private_nic_required       = false
  }

  startup = {
    cp = templatefile("${path.module}/startup/node.sh.tftpl", {
      role               = "control"
      cluster_name       = var.cluster_name
      admin_cidrs        = var.admin_cidrs
      driver_check       = "none"
      gpu_expected_count = 0
      common             = templatefile("${path.module}/../par/cloud-init/common.sh.tftpl", merge(local.common_bootstrap, { node_name = local.cp_name }))
    })
    gpu = templatefile("${path.module}/startup/node.sh.tftpl", {
      role               = "gpu"
      cluster_name       = var.cluster_name
      admin_cidrs        = var.admin_cidrs
      driver_check       = var.gpu_driver_check
      gpu_expected_count = var.gpu_expected_count
      common             = templatefile("${path.module}/../par/cloud-init/common.sh.tftpl", merge(local.common_bootstrap, { node_name = local.gpu_name }))
    })
  }
}

resource "verda_ssh_key" "admin" {
  count = local.any_enabled ? 1 : 0

  name       = "${var.cluster_name}-admin"
  public_key = trimspace(var.ssh_public_key)

  lifecycle {
    precondition {
      condition     = trimspace(var.ssh_public_key) != ""
      error_message = "No SSH public key. Run the scripts in scripts/fin/, which derive it from SSH_PRIVATE_KEY_PATH in .env."
    }
  }
}

resource "verda_startup_script" "cp" {
  count = var.cp_enabled ? 1 : 0

  name   = "${local.cp_name}-bootstrap"
  script = local.startup.cp
}

resource "verda_startup_script" "gpu" {
  count = var.gpu_enabled ? 1 : 0

  name   = "${local.gpu_name}-bootstrap"
  script = local.startup.gpu
}

########################################
# Control plane: kubeadm, ArgoCD, a light Prometheus and the NVCRE controller,
# which has to run on a node without GPUs.
########################################

resource "verda_instance" "cp" {
  count = var.cp_enabled ? 1 : 0

  hostname          = local.cp_name
  description       = "EU1 fin control plane"
  instance_type     = var.cp_instance_type
  image             = var.cp_image
  location          = var.cp_location
  ssh_key_ids       = [verda_ssh_key.admin[0].id]
  startup_script_id = verda_startup_script.cp[0].id

  # Deleted with the instance, permanently, not moved to the trash. make
  # fin-down also deletes it explicitly by ID and then checks the trash.
  os_volume = {
    name       = "${local.cp_name}-os"
    size       = var.cp_os_volume_size_gb
    type       = "NVMe"
    on_destroy = "delete_permanently"
  }

  timeouts = {
    create = "20m"
  }
}

########################################
# GPU node: 2x H200 SXM5 in a window, or a CPU stand-in for the rehearsal.
########################################

resource "verda_instance" "gpu" {
  count = var.gpu_enabled ? 1 : 0

  hostname          = local.gpu_name
  description       = "EU1 fin GPU node"
  instance_type     = var.gpu_instance_type
  image             = var.gpu_image
  location          = var.gpu_location
  is_spot           = var.gpu_is_spot
  ssh_key_ids       = [verda_ssh_key.admin[0].id]
  startup_script_id = verda_startup_script.gpu[0].id

  os_volume = {
    name       = "${local.gpu_name}-os"
    size       = var.gpu_os_volume_size_gb
    type       = "NVMe"
    on_destroy = "delete_permanently"
    # A reclaimed spot instance must not leave its volume billing.
    on_spot_discontinue = var.gpu_is_spot ? "delete_permanently" : null
  }

  timeouts = {
    create = "20m"
  }
}
