# cloudflare — proxied DNS in front of the website only (hardening Phase 21,
# A11): L3/4 DDoS absorption, managed WAF + OWASP core ruleset, a per-IP
# rate limit, edge TLS. Deliberately NOT the API — the plan's own text is
# explicit ("do not double-proxy the API without measuring"): the ALB
# already terminates TLS and has its own health checks/OIDC, and adding a
# second proxy hop in front of it is a real latency/complexity cost that
# needs its own measurement, not a default.
#
# A separate root module from envs/{dev,staging,prod} on purpose — a
# different provider (Cloudflare, not AWS), a different account/credential
# entirely, and one Cloudflare zone covers the whole domain rather than
# mapping to one AWS environment.
#
# Dormant by default (`enable_cloudflare = false`) — OPERATOR-ACTIONS.md H1:
# needs a real Cloudflare account, an API token (Zone: DNS edit, Firewall
# edit) as CLOUDFLARE_API_TOKEN, the zone id, and the website's actual
# origin hostname before any of this can apply. `terraform validate` needs
# none of that — only `plan`/`apply` do.

terraform {
  required_version = ">= 1.6"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Reads CLOUDFLARE_API_TOKEN from the environment — never put the token in
# a .tfvars file or in state-adjacent config.
provider "cloudflare" {}

variable "enable_cloudflare" {
  description = "Off until the operator has a Cloudflare account + zone (OPERATOR-ACTIONS.md H1). No resources are created while false."
  type        = bool
  default     = false
}

variable "zone_id" {
  description = "The Cloudflare zone id for the domain (from the Cloudflare dashboard)."
  type        = string
  default     = ""
}

variable "website_hostname" {
  description = "DNS name to proxy, e.g. \"www\" or \"@\" for the apex."
  type        = string
  default     = "www"
}

variable "website_origin" {
  description = "CNAME target — the website's actual hosting origin (e.g. a Vercel deployment's cname.vercel-dns.com.)."
  type        = string
  default     = ""
}

variable "ssl_mode" {
  description = "Cloudflare edge TLS mode. \"strict\" needs a valid cert at the origin (Vercel provides one) — verify before applying, \"full\" tolerates a self-signed one."
  type        = string
  default     = "strict"
}

variable "security_level" {
  type    = string
  default = "medium"
}

variable "rate_limit_requests_per_minute" {
  description = "Per-IP request budget before Cloudflare blocks for rate_limit_mitigation_timeout_s."
  type        = number
  default     = 300
}

variable "rate_limit_mitigation_timeout_s" {
  type    = number
  default = 600
}

locals {
  enabled = var.enable_cloudflare
}

# ── DNS (proxied) ───────────────────────────────────────────────────────────
resource "cloudflare_dns_record" "website" {
  count   = local.enabled ? 1 : 0
  zone_id = var.zone_id
  name    = var.website_hostname
  type    = "CNAME"
  content = var.website_origin
  ttl     = 1 # "automatic" — required by the API when proxied = true
  proxied = true
}

# ── Edge TLS + baseline security posture ────────────────────────────────────
resource "cloudflare_zone_setting" "ssl" {
  count      = local.enabled ? 1 : 0
  zone_id    = var.zone_id
  setting_id = "ssl"
  value      = var.ssl_mode
}

resource "cloudflare_zone_setting" "min_tls_version" {
  count      = local.enabled ? 1 : 0
  zone_id    = var.zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "security_level" {
  count      = local.enabled ? 1 : 0
  zone_id    = var.zone_id
  setting_id = "security_level"
  value      = var.security_level
}

resource "cloudflare_zone_setting" "always_use_https" {
  count      = local.enabled ? 1 : 0
  zone_id    = var.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# ── Bot management (free-tier Bot Fight Mode) ───────────────────────────────
resource "cloudflare_bot_management" "this" {
  count      = local.enabled ? 1 : 0
  zone_id    = var.zone_id
  fight_mode = true
}

# ── Managed WAF — Cloudflare Managed Ruleset + OWASP Core Ruleset ───────────
# Fixed, Cloudflare-published ruleset ids (stable across accounts/zones):
# https://developers.cloudflare.com/waf/managed-rules/reference/cloudflare-managed-ruleset/
resource "cloudflare_ruleset" "managed_waf" {
  count       = local.enabled ? 1 : 0
  zone_id     = var.zone_id
  name        = "Managed WAF"
  description = "Cloudflare Managed Ruleset + OWASP Core Ruleset"
  kind        = "zone"
  phase       = "http_request_firewall_managed"
  rules = [
    {
      ref         = "execute_cloudflare_managed_ruleset"
      description = "Cloudflare Managed Ruleset"
      expression  = "true"
      action      = "execute"
      action_parameters = {
        id = "efb7b8c949ac4650a09736fc376e9aee"
      }
    },
    {
      ref         = "execute_owasp_core_ruleset"
      description = "OWASP Core Ruleset"
      expression  = "true"
      action      = "execute"
      action_parameters = {
        id = "4814384a9e5d4991b9815dcfc25d2f1f"
      }
    },
  ]
}

# ── Rate limiting — the L3/4-adjacent abuse case the plan calls out
# (volumetric floods before they reach the ALB). Per-IP, zone-wide; a
# per-route limit can be layered later with a narrower `expression` if one
# route needs a tighter budget than the rest of the site.
resource "cloudflare_ruleset" "rate_limit" {
  count   = local.enabled ? 1 : 0
  zone_id = var.zone_id
  name    = "Website rate limit"
  kind    = "zone"
  phase   = "http_ratelimit"
  rules = [
    {
      description = "Per-IP request budget"
      expression  = "true"
      action      = "block"
      ratelimit = {
        characteristics     = ["ip.src"]
        period              = 60
        requests_per_period = var.rate_limit_requests_per_minute
        mitigation_timeout  = var.rate_limit_mitigation_timeout_s
      }
    },
  ]
}
