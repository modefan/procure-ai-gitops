# Inputs of the hosted VM. bootstrap/hosted/new-hosted-cluster.ps1 passes ssh_public_key_path and k3s_version (pinned in
# bootstrap/common.ps1); the rest are the approved defaults. The Hetzner API token comes from the environment (HCLOUD_TOKEN), never a file.

variable "server_type" {
  description = "Hetzner server type. Only the types Dale approved (plan 08, 2026-11-07): cx43 (EUR 15.99 net per month) or cx53 (EUR 29.49 net), whichever is in stock; plus the IPv4."
  type        = string
  default     = "cx43"

  validation {
    # A bigger type costs more: change this list only with Dale's OK (CLAUDE.md "What Claude may do"; also bootstrap/common.ps1
    # HostedApprovedTypes, which holds the approved prices).
    condition     = contains(["cx43", "cx53"], var.server_type)
    error_message = "Only cx43 and cx53 are approved. Ask Dale before using another server type."
  }
}

variable "location" {
  description = "Hetzner location: Falkenstein (fsn1), Nuremberg (nbg1) or Helsinki (hel1), all in network zone eu-central."
  type        = string
  default     = "fsn1"

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1"], var.location)
    error_message = "Only fsn1, nbg1 and hel1 (network zone eu-central) are approved."
  }
}

variable "network_zone" {
  description = "Network zone of the private subnet; must contain the location."
  type        = string
  default     = "eu-central"
}

variable "image" {
  description = "Operating system image: the current Ubuntu LTS on Hetzner."
  type        = string
  default     = "ubuntu-26.04"
}

variable "server_name" {
  description = "Server (and host) name."
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

variable "k3s_version" {
  description = "Pinned k3s release, e.g. v1.35.10+k3s1 (bootstrap/common.ps1, HostedK3sVersion)."
  type        = string

  validation {
    condition     = can(regex("^v1\\.[0-9]+\\.[0-9]+\\+k3s[0-9]+$", var.k3s_version))
    error_message = "k3s_version must be a k3s release tag like v1.35.10+k3s1."
  }
}

variable "network_cidr" {
  description = "Private network of the VM. The Kubernetes API listens only on the server's address in it."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet of the private network."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_ip" {
  description = "The server's fixed address in the subnet (node IP, API bind address; open-tunnel.ps1 forwards to it)."
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
  description = "Host names that point at the server (A and AAAA each): the app, Keycloak and the Aspire dashboard."
  type        = list(string)
  default     = ["procure", "auth", "dashboard"]
}

variable "dns_ttl" {
  description = "TTL of the records in seconds (short: a recreated server gets new addresses)."
  type        = number
  default     = 300
}
