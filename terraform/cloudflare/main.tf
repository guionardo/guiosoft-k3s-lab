locals {
  zone_name    = "guiosoft.info"
  tunnel_cname = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id = var.cloudflare_account_id
  name       = var.cloudflare_tunnel_name
  config_src = "cloudflare"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id

  config = {
    ingress = [
      # Firecrawl is LAN-only. Keep this rule before the wildcard so requests
      # arriving through Cloudflare never reach Traefik, even though the
      # wildcard DNS record still points *.guiosoft.info at this tunnel.
      {
        hostname       = "firecrawl.guiosoft.info"
        service        = "http_status:404"
        origin_request = {}
      },
      {
        hostname       = "*.guiosoft.info"
        service        = "http://127.0.0.1:80"
        origin_request = {}
      },
      {
        service = "http_status:404"
      }
    ]
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*.guiosoft.info"
  type    = "CNAME"
  content = local.tunnel_cname
  ttl     = 1
  proxied = true

  lifecycle {
    prevent_destroy = true
  }
}
