output "cluster_name" {
  description = "Prefix of every resource name on this site, used by the leftover sweep."
  value       = var.cluster_name
}

output "cp_enabled" {
  description = "Whether the control plane is declared, and therefore billing."
  value       = var.cp_enabled
}

output "cp_name" {
  description = "Kubernetes node name of the control plane."
  value       = local.cp_name
}

output "cp_location" {
  description = "Verda location of the control plane."
  value       = var.cp_location
}

output "cp_ip" {
  description = "Public address of the control plane, or null when it doesn't exist."
  value       = var.cp_enabled ? verda_instance.cp[0].ip : null
}

output "cp_instance_type" {
  description = "Instance type of the control plane, used by the session log."
  value       = var.cp_instance_type
}

output "gpu_enabled" {
  description = "Whether the GPU node is declared, and therefore billing."
  value       = var.gpu_enabled
}

output "gpu_name" {
  description = "Kubernetes node name of the GPU node."
  value       = local.gpu_name
}

output "gpu_ip" {
  description = "Public address of the GPU node, or null when it doesn't exist."
  value       = var.gpu_enabled ? verda_instance.gpu[0].ip : null
}

output "gpu_instance_type" {
  description = "Instance type of the GPU node, used by the session log."
  value       = var.gpu_instance_type
}

# What make fin-down deletes through the API: each instance with its own OS
# volume ID in volume_ids.
output "instances" {
  description = "Every instance of the site with its OS volume, keyed by Terraform address."
  value = merge(
    var.cp_enabled ? { "verda_instance.cp[0]" = { id = verda_instance.cp[0].id, os_volume_id = verda_instance.cp[0].os_volume_id, hostname = local.cp_name } } : {},
    var.gpu_enabled ? { "verda_instance.gpu[0]" = { id = verda_instance.gpu[0].id, os_volume_id = verda_instance.gpu[0].os_volume_id, hostname = local.gpu_name } } : {},
  )
}
