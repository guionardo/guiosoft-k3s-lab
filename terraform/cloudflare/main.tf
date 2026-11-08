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
      # Registry is LAN-only. Like Firecrawl, this rule must precede the
      # wildcard: the DNS record for *.guiosoft.info still points here, so
      # without it the registry would be reachable from the internet as soon
      # as its Traefik Ingress reconciles.
      {
        hostname       = "registry.guiosoft.info"
        service        = "http_status:404"
        origin_request = {}
      },
      # Firecrawl is LAN-only. Keep this rule before the wildcard so requests
      # arriving through Cloudflare never reach Traefik, even though the
      # wildcard DNS record still points *.guiosoft.info at this tunnel.
      {
        hostname       = "firecrawl.guiosoft.info"
        service        = "http_status:404"
        origin_request = {}
      },
      # Keycloak is LAN-only. Same pattern: block public access before the
      # wildcard so the OIDC issuer is not reachable from the internet.
      {
        hostname       = "auth.guiosoft.info"
        service        = "http_status:404"
        origin_request = {}
      },
      {
        hostname = "*.guiosoft.info"
        # This origin must be reachable by both the current host systemd
        # connector and the future cloudflared Pod during the migration.
        # Do not use 127.0.0.1 here: inside Kubernetes it would point at the
        # cloudflared Pod itself instead of Traefik/ServiceLB on the node.
        service        = var.cloudflare_tunnel_origin_url
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
