# The hosted demo (plan 08 ruling 10, Dale's decisions 2026-11-07): one Contabo Cloud VPS with k3s (installed by cloud-init), Contabo's
# firewall (inbound 22, 80, 443 only), the VM's SSH key, and the Cloudflare DNS records procure, auth and dashboard.daleabels.com.
#
# Money: Dale bought the VPS himself (instance 203735351, Cloud VPS 8, EUR 14.00 a month, monthly term). Terraform ADOPTS that instance
# (existing_instance_id): its first apply reinstalls the VM with the image, the SSH key and cloud-init below. Terraform never orders an
# instance (bootstrap/hosted/new-hosted-cluster.ps1 refuses any plan that would) and never cancels it: the provider's delete is
# "cancel instance", so prevent_destroy blocks it, and new-hosted-cluster.ps1 -Destroy removes only the free resources. Cancelling is
# Dale's call, in the Contabo panel (procure-ai docs/hosting.md). The firewall, the SSH key secret and the DNS records are free.
#
# Run Terraform here ONLY through bootstrap/hosted/new-hosted-cluster.ps1: its plan check guards every apply and destroy. prevent_destroy
# protects the instance only while its block is in this file. NEVER delete the contabo_instance block: a raw `terraform apply` would then
# cancel the VPS. To stop managing the VM, use `terraform state rm contabo_instance.vps` or a
# `removed { from = contabo_instance.vps  lifecycle { destroy = false } }` block.
#
# State is local and outside every repo: new-hosted-cluster.ps1 runs
#   terraform init -backend-config="path=%USERPROFILE%\.procure-ai\hosted\terraform.tfstate"

terraform {
  required_version = ">= 1.17.0"

  required_providers {
    contabo = {
      source  = "contabo/contabo"
      version = "0.1.44"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.28.1"
    }
  }

  # Path given at init time (partial configuration), so no state file can land in this repo.
  backend "local" {}
}

# Credentials from the environment (CNTB_OAUTH2_CLIENT_ID, CNTB_OAUTH2_CLIENT_SECRET, CNTB_OAUTH2_USER, CNTB_OAUTH2_PASS), which
# new-hosted-cluster.ps1 fills from Dale's user env vars CONTABO_*. Nothing in a file.
provider "contabo" {}

# Token from the environment variable CLOUDFLARE_API_TOKEN (account-owned token claude-dns: DNS Write + Zone Read on daleabels.com only).
provider "cloudflare" {}

# The VM's admin key (public half only; the private half never leaves Dale's PC). Contabo puts it on the default user (root) at the
# reinstall; cloud-init then gives the same key to the admin user and turns root login off.
resource "contabo_secret" "ssh" {
  name  = "${var.server_name}-admin"
  type  = "ssh"
  value = trimspace(file(var.ssh_public_key_path))
}

resource "contabo_instance" "vps" {
  existing_instance_id = var.instance_id
  display_name         = var.server_name
  image_id             = var.image_id
  default_user         = "root"
  ssh_keys             = [tonumber(contabo_secret.ssh.id)]
  # Keeps the root password Dale received with the VPS valid for the Contabo console (a Contabo password secret holding the same value,
  # created by new-hosted-cluster.ps1; null leaves it out).
  root_password = var.root_password_secret_id
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    admin_user     = var.admin_user
    ssh_public_key = trimspace(file(var.ssh_public_key_path))
    k3s_version    = var.k3s_version
    node_ip        = var.node_ip
  })

  lifecycle {
    # The provider's delete cancels the paid instance: never from Terraform.
    prevent_destroy = true
    # Each of these reinstalls the VM (all data lost) when it changes. They are sent on the first apply (the adoption); afterwards a change
    # is made on the running VM over SSH, and cloud-init.yaml is kept in line for the next deliberate reinstall
    # (new-hosted-cluster.ps1 -Reinstall). add_ons are what Dale bought; Terraform neither adds nor removes any.
    ignore_changes = [user_data, image_id, ssh_keys, default_user, root_password, add_ons]
  }
}

locals {
  ipv4 = contabo_instance.vps.ip_config[0].v4[0].ip
  # The VM's IPv6 address (reported only; k3s is IPv4 single-stack, so nothing but SSH answers on IPv6 and there are no AAAA records).
  # The API writes it in full (2a02:...:0000:0001); cidrhost gives the short form.
  ipv6 = cidrhost("${contabo_instance.vps.ip_config[0].v6[0].ip}/128", 0)
}

# Contabo's firewall (free): inbound only TCP 22, 80, 443 from anywhere, IPv4 and IPv6; everything else is dropped (no ICMP). The
# Kubernetes API, the kubelet and kube-proxy's health port also listen only on the node address (cloud-init), so they stay closed even
# without this firewall.
resource "contabo_firewall" "public" {
  name        = "${var.server_name}-fw"
  description = "procure-ai hosted VM: in tcp 22, 80, 443 only (Terraform, procure-ai-gitops infra/hosted)"
  status      = "active"
  # The approved ID (known at plan time), not contabo_instance.vps.id: a -Reinstall (state rm + adopt again) then changes nothing here, so
  # the provider never unassigns and reassigns the firewall, and the VM is never without it.
  instance_ids = [tonumber(var.instance_id)]
  depends_on   = [contabo_instance.vps]

  rules {
    inbound {
      protocol   = "tcp"
      action     = "accept"
      status     = "active"
      dest_ports = ["22", "80", "443"]
      src_cidr {
        ipv4 = ["0.0.0.0/0"]
        ipv6 = ["::/0"]
      }
    }
  }

  lifecycle {
    # Contabo appends its own last rule "Block all traffic" (action drop) to every firewall, and provider 0.1.44 reads it back as a
    # second inbound rule that the configuration does not have, so every plan would show a change. The rules are written on create;
    # bootstrap/hosted/Test-HostBaseline.ps1 checks the live rules (the accept rule above plus Contabo's drop rule) through the API.
    # To change a rule: edit it here and recreate the firewall (terraform apply -replace=contabo_firewall.public), which is free.
    ignore_changes = [rules]
  }
}

# An A record for each host, straight to the server (DNS only: Traefik terminates TLS with Let's Encrypt, Task 12). No AAAA: k3s is
# IPv4 single-stack (Traefik's host ports are IPv4 only), so an AAAA record would send IPv6 clients and Let's Encrypt to an
# address where 80/443 do not answer (controller ruling 2026-11-07; Task 12 kept IPv4 only). Only these three records are
# managed here; the apex and anything else in the zone are not touched.
locals {
  dns_records = { for host in var.dns_hosts : "${host}-A" => { name = "${host}.${var.domain}", type = "A", content = local.ipv4 } }
}

resource "cloudflare_dns_record" "host" {
  for_each = local.dns_records

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  ttl     = var.dns_ttl
  proxied = false
  comment = "procure-ai hosted VM (Terraform, procure-ai-gitops infra/hosted)"
}
