output "instance_id" {
  description = "Contabo instance ID."
  value       = contabo_instance.vps.id
}

output "product_id" {
  description = "Contabo product (V155 = Cloud VPS 8)."
  value       = contabo_instance.vps.product_id
}

output "ipv4_address" {
  description = "Public IPv4 (the A records point here)."
  value       = local.ipv4
}

output "ipv6_address" {
  description = "Public IPv6 (only SSH answers there; no AAAA records, k3s is IPv4 only)."
  value       = local.ipv6
}

output "node_ip" {
  description = "Node address on the dummy interface; the Kubernetes API listens only here (reach it through bootstrap/hosted/open-tunnel.ps1)."
  value       = var.node_ip
}

output "admin_user" {
  description = "The SSH user."
  value       = var.admin_user
}

output "firewall_id" {
  description = "Contabo firewall ID."
  value       = contabo_firewall.public.id
}

output "dns_names" {
  description = "The host names that point at the server."
  value       = sort(distinct([for r in cloudflare_dns_record.host : r.name]))
}

output "ssh_key_secret_id" {
  description = "Contabo secret ID of the VM's SSH key (new-hosted-cluster.ps1 checks the reinstall put it on the instance)."
  value       = contabo_secret.ssh.id
}
