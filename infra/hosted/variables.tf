# Inputs of the hosted setup. bootstrap/hosted/new-hosted-cluster.ps1 passes ssh_public_key_path, k3s_version (pinned in
# bootstrap/common.ps1) and root_password_secret_id; the rest are the approved defaults. Credentials come from the environment only.

variable "instance_id" {
  description = "The Contabo instance Dale bought (Cloud VPS 8, EU, EUR 14.00 a month). Terraform adopts it; it never orders one."
  type        = string
  default     = "203735351"

  validation {
    # Another instance is another contract: change this only with Dale's OK (CLAUDE.md "What Claude may do").
    condition     = var.instance_id == "203735351"
    error_message = "Only instance 203735351 is approved. Ask Dale before adopting another Contabo instance."
  }
}

variable "image_id" {
  description = "Contabo standard image: ubuntu-26.04 (the current Ubuntu LTS; GET /v1/compute/images). Fallback ubuntu-24.04: d64d5c6c-9dda-4e38-8174-0ee282474d8a."
  type        = string
  default     = "f5193fe6-d547-4726-9271-cdb2819833fd"
}

variable "server_name" {
  description = "Display name of the VM and prefix of its firewall and key."
  type        = string
  default     = "procure-hosted"
}

variable "admin_user" {
  description = "The one non-root sudo user that may log in over SSH (key only)."
  type        = string
  default     = "procure"
}

variable "ssh_public_key_path" {
  description = "Public half of the VM's SSH key (%USERPROFILE%\\.procure-ai\\hosted\\procure-hosted_ed25519.pub; the private half never leaves Dale's PC)."
  type        = string
}

variable "root_password_secret_id" {
  description = "ID of the Contabo password secret holding the root password Dale received with the VPS (console only; SSH root login is off). Null: none."
  type        = number
  default     = null
}

variable "k3s_version" {
  description = "Pinned k3s release, e.g. v1.35.10+k3s1 (bootstrap/common.ps1, HostedK3sVersion)."
  type        = string

  validation {
    condition     = can(regex("^v1\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version must be a k3s release tag like v1.35.10+k3s1."
  }
}

variable "node_ip" {
  description = "Node address on a dummy interface (Contabo's private networks are a paid add-on): the Kubernetes API, the kubelet and kube-proxy's health port listen only here; open-tunnel.ps1 forwards to it over SSH."
  type        = string
  default     = "10.0.1.2"
}

# --- Cloudflare DNS (Dale's decision 2026-11-07: the whole hosted setup in this one Terraform root) ---------------------------------
# Token from the environment variable CLOUDFLARE_API_TOKEN: the account-owned token claude-dns (DNS Write + Zone Read, daleabels.com only).

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID of daleabels.com."
  type        = string
  default     = "93c854c6f17e0cbb8f2b7e9395f7828c"
}

variable "domain" {
  description = "The zone's domain; the records are <host>.<domain>. The apex and every other record are left alone."
  type        = string
  default     = "daleabels.com"
}

variable "dns_hosts" {
  description = "Host names that point at the server (one A record each): the app, Keycloak, the Aspire dashboard and the operator's own hosts (plan 08b Task 4). Equal to $HostedDnsHosts in bootstrap/common.ps1."
  type        = list(string)
  default     = ["procure", "auth", "dashboard", "pgadmin", "mongo", "redis", "rabbitmq", "dashboard-direct"]
}

variable "dns_ttl" {
  description = "TTL of the records in seconds (short, so a move to another server is quick)."
  type        = number
  default     = 300
}
