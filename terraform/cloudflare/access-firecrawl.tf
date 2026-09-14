# Firecrawl public Access resources are intentionally kept during phase 1 of
# the LAN-only cutover. The tunnel now has an explicit firecrawl.guiosoft.info
# -> http_status:404 rule before the *.guiosoft.info wildcard.
#
# Apply and validate that public requests receive 404 before removing these
# resources in phase 2. This ordering prevents a window where removing Access
# would expose Firecrawl through the wildcard tunnel.

resource "cloudflare_zero_trust_access_service_token" "firecrawl_hermes" {
  account_id = var.cloudflare_account_id
  name       = "firecrawl-hermes"
  duration   = "8760h"
  enabled    = true
}

resource "cloudflare_zero_trust_access_service_token" "firecrawl_opencode" {
  account_id = var.cloudflare_account_id
  name       = "firecrawl-opencode"
  duration   = "8760h"
  enabled    = true
}

resource "cloudflare_zero_trust_access_application" "firecrawl" {
  account_id = var.cloudflare_account_id
  name       = "Firecrawl Agents"
  type       = "self_hosted"

  destinations = [
    {
      type = "public"
      uri  = "firecrawl.guiosoft.info"
    }
  ]

  service_auth_401_redirect = true
  app_launcher_visible      = false
  skip_interstitial         = true

  policies = [
    {
      name       = "Allow Hermes and OpenCode service tokens"
      decision   = "non_identity"
      precedence = 1
      include = [
        {
          service_token = {
            token_id = cloudflare_zero_trust_access_service_token.firecrawl_hermes.id
          }
        },
        {
          service_token = {
            token_id = cloudflare_zero_trust_access_service_token.firecrawl_opencode.id
          }
        }
      ]
    }
  ]
}
