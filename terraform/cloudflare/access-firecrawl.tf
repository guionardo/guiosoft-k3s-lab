# Firecrawl is intentionally LAN-only as of 2026-09-14.
#
# Hermes and OpenCode were validated against http://firecrawl.guiosoft.info,
# resolved by the LAN split-horizon DNS directly to the K3s/Traefik host.
# Cloudflare Access application and Service Token resources were removed from
# configuration so the next Terraform plan/apply can destroy the obsolete
# public authentication resources.
#
# Keep this marker until the destroy plan has been reviewed and applied; it
# documents why the previous resources must not be recreated.
