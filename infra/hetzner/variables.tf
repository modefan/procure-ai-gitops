# Inputs of the hosted VM. bootstrap/hosted/new-hosted-cluster.ps1 passes ssh_public_key_path and k3s_version (pinned in
# bootstrap/common.ps1); the rest are the approved defaults. The Hetzner API token comes from the environment (HCLOUD_TOKEN), never a file.

variable "server_type" {
  description = "Hetzner server type. Only the type Dale approved (plan 08 D2, 2026-11-07: EUR 15.99 net per month in fsn1, plus the IPv4)."
  type        = string
  default     = "cx43"

  validation {
    # A bigger type costs more: change this list only with Dale's OK (CLAUDE.md "What Claude may do").
    condition     = contains(["cx43"], var.server_type)
    error_message = "Only cx43 is approved (8 shared vCPU, 16 GB, 160 GB). Ask Dale before changing the server type."
  }
}

variable "location" {
  description = "Hetzner location (Falkenstein, Germany)."
  type        = string
  default     = "fsn1"
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
