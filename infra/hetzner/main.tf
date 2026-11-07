# The hosted demo VM on Hetzner Cloud (plan 08 ruling 10): one server with k3s (installed by cloud-init), a private network that the
# Kubernetes API listens on, a firewall that lets in only SSH, HTTP and HTTPS, and the SSH key. Billed: the server and its primary IPv4
# (created with the server). Free: the firewall, the network and the SSH key. A stopped server still bills; `terraform destroy` pauses
# the cost (procure-ai docs/hosting.md).
#
# State is local and outside every repo: bootstrap/hosted/new-hosted-cluster.ps1 runs
#   terraform init -backend-config="path=%USERPROFILE%\.procure-ai\hosted\terraform.tfstate"

terraform {
  required_version = ">= 1.17.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.70.2"
    }
  }

  # Path given at init time (partial configuration), so no state file can land in this repo.
  backend "local" {}
}

# Token from the environment variable HCLOUD_TOKEN (project procure-ai, Read & Write).
provider "hcloud" {}

locals {
  labels = {
    app        = "procure-ai"
    managed-by = "terraform"
  }
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.server_name}-admin"
  public_key = trimspace(file(var.ssh_public_key_path))
  labels     = local.labels
}

resource "hcloud_network" "private" {
  name     = "${var.server_name}-net"
  ip_range = var.network_cidr
  labels   = local.labels
}

resource "hcloud_network_subnet" "private" {
  network_id   = hcloud_network.private.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_cidr
}

# Inbound: only 22 (SSH, key only), 80 and 443 (Traefik), over IPv4 and IPv6. Everything else, including the Kubernetes API (6443, which
# listens only on the private address anyway), the kubelet and flannel, is dropped. Outbound is not restricted (no outbound rules).
resource "hcloud_firewall" "public" {
  name   = "${var.server_name}-fw"
  labels = local.labels

  dynamic "rule" {
    for_each = {
      "22"  = "SSH (key only)"
      "80"  = "HTTP (redirects to HTTPS)"
      "443" = "HTTPS"
    }
    content {
      description = rule.value
      direction   = "in"
      protocol    = "tcp"
      port        = rule.key
      source_ips  = ["0.0.0.0/0", "::/0"]
    }
  }
}

resource "hcloud_server" "node" {
  name        = var.server_name
  server_type = var.server_type
  location    = var.location
  image       = var.image
  ssh_keys    = [hcloud_ssh_key.admin.id]
  labels      = local.labels

  firewall_ids = [hcloud_firewall.public.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.private.id
    ip         = var.private_ip
  }

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    admin_user     = var.admin_user
    ssh_public_key = trimspace(file(var.ssh_public_key_path))
    k3s_version    = var.k3s_version
    private_ip     = var.private_ip
  })

  lifecycle {
    # cloud-init runs on the first boot only: a change to cloud-init.yaml (or a newer image) must not silently replace the server and
    # its data. Apply such a change on the running VM over SSH, and keep cloud-init.yaml in line for the next fresh server
    # (`terraform apply -replace=hcloud_server.node`, deliberately).
    ignore_changes = [user_data, image, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.private]
}
