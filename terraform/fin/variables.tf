########################################
# Site fin, Verda Finland
#
# The whole site exists only during a GPU window. Placement, instance types and
# images come from the free preflight (scripts/fin/preflight.sh), which the up
# scripts turn into cp.auto.tfvars and gpu.auto.tfvars. Nothing is created by a
# bare terraform apply: both nodes default to disabled.
########################################

variable "cluster_name" {
  description = "Prefix applied to every resource name and used as the Kubernetes cluster name."
  type        = string
  default     = "eu1-fin"
}

variable "ssh_public_key" {
  description = <<-EOT
    Public SSH key registered on both nodes. The scripts derive it from
    SSH_PRIVATE_KEY_PATH in .env and pass it as TF_VAR_ssh_public_key, as on par.
  EOT
  type        = string
  default     = ""
}

variable "admin_cidrs" {
  description = <<-EOT
    Source ranges allowed to reach SSH and the Kubernetes API on the nodes'
    public addresses. Verda has no cloud firewall, so this goes into nftables on
    each node. Open by default because a laptop on a residential connection has
    no stable address; SSH is key only and the API is client certificate only.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

########################################
# Control plane node
########################################

variable "cp_enabled" {
  description = "Whether the control plane node exists. scripts/fin/cp-up.sh and down.sh own it."
  type        = bool
  default     = false
}

variable "cp_location" {
  description = "Verda location code for the control plane. Sent to the API as location_code."
  type        = string
  default     = "FIN-01"
}

variable "cp_instance_type" {
  description = "Instance type of the control plane, the preflight's pick of the CPU types orderable in that location."
  type        = string
  default     = "CPU.8V.32G"
}

variable "cp_image" {
  description = "Image type of the control plane. Plain Ubuntu 26.04: no driver, no CUDA, the same release as the GPU node."
  type        = string
  default     = "26.04.base"
}

variable "cp_os_volume_size_gb" {
  description = "OS volume of the control plane, NVMe at 0.20 USD per GB per month."
  type        = number
  default     = 100
}

########################################
# GPU node
########################################

variable "gpu_enabled" {
  description = "Whether the GPU node exists. scripts/fin/gpu-up.sh and down.sh own it."
  type        = bool
  default     = false
}

variable "gpu_location" {
  description = "Verda location code for the GPU node, where the preflight found it orderable."
  type        = string
  default     = "FIN-01"
}

variable "gpu_instance_type" {
  description = <<-EOT
    Instance type of the GPU node. 2H200.141S.88V is two H200 SXM5 with NVLink.
    The rehearsal sets a CPU type here and boots the same GPU image, which tests
    everything on the node except the GPUs themselves.
  EOT
  type        = string
  default     = "2H200.141S.88V"
}

variable "gpu_is_spot" {
  description = "Order the GPU node on spot. Pre-approved by Yassine as the one fallback when on demand is unavailable."
  type        = bool
  default     = false
}

variable "gpu_image" {
  description = <<-EOT
    Image type of the GPU node. The provider image owns the driver on fin
    (ADR 0002), so this is the one plain Ubuntu image with it preinstalled.
    Verda's API names its CUDA release, not its driver; the node's first boot
    records the driver.
  EOT
  type        = string
  default     = "26.04.cuda13.4"
}

variable "gpu_os_volume_size_gb" {
  description = "OS volume of the GPU node. Container images for NCCL, NVCRE and PyTorch need room."
  type        = number
  default     = 200
}

variable "gpu_driver_check" {
  description = <<-EOT
    How the GPU node's bootstrap checks the preinstalled driver. "required": the
    driver must load and nvidia-smi must see gpu_expected_count GPUs, or the
    bootstrap fails within the first minute. "rehearsal": the driver packages
    must be present, for a CPU stand-in booting the GPU image.
  EOT
  type        = string
  default     = "required"

  validation {
    condition     = contains(["required", "rehearsal"], var.gpu_driver_check)
    error_message = "gpu_driver_check must be required or rehearsal."
  }
}

variable "gpu_expected_count" {
  description = "GPUs nvidia-smi must list when gpu_driver_check is required."
  type        = number
  default     = 2
}

########################################
# Kubernetes, the same pins as par
########################################

variable "kubernetes_minor" {
  description = "Kubernetes minor version, which selects the pkgs.k8s.io repository."
  type        = string
  default     = "1.36"
}

variable "kubernetes_package_version" {
  description = "Exact package version for kubelet, kubeadm and kubectl, the same as par."
  type        = string
  default     = "1.36.5-1.1"
}

variable "containerd_package_version" {
  description = "containerd.io version without the distribution suffix, the same as par. GPU Operator v26.7.x validates 2.0 to 2.3."
  type        = string
  default     = "2.3.6-1"
}
