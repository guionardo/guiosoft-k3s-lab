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
