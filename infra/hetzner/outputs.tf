output "server_id" {
  description = "Hetzner server ID."
  value       = hcloud_server.node.id
}

output "server_type" {
  description = "Server type (billed)."
  value       = hcloud_server.node.server_type
}

output "location" {
  description = "Location."
  value       = hcloud_server.node.location
}

output "ipv4_address" {
  description = "Public IPv4 (the DNS records of Task 12 point here)."
  value       = hcloud_server.node.ipv4_address
}

output "ipv6_address" {
  description = "Public IPv6 address of the server."
  value       = hcloud_server.node.ipv6_address
}

output "private_ip" {
  description = "Private address; the Kubernetes API listens only here (reach it through bootstrap/hosted/open-tunnel.ps1)."
  value       = var.private_ip
}

output "admin_user" {
  description = "The SSH user."
  value       = var.admin_user
}

output "dns_names" {
  description = "The host names that point at the server."
  value       = sort(distinct([for r in cloudflare_dns_record.host : r.name]))
}
