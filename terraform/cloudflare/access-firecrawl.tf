# Firecrawl is LAN-only as of 2026-09-14.
#
# Public requests for firecrawl.guiosoft.info are explicitly denied by the
# Cloudflare Tunnel ingress rule in main.tf before the *.guiosoft.info wildcard.
# LAN clients use split-horizon DNS and reach Traefik directly, bypassing the
# public Cloudflare path.
#
# The former Cloudflare Access application and the Hermes/OpenCode service
# tokens were removed after the public 404 path and LAN access were validated.
