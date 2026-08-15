# Public DNS for ghostinthefactory.com.
#
# The zone lives here so the registrar just delegates NS once, and so the
# instance role can answer DNS-01 challenges (Caddy's route53 module) for
# certs on names that never resolve publicly to the box — the dashboard A
# record points at the Tailscale address, reachable only inside the tailnet.
#
#   factory.<domain> → tailnet IP (set var.factory_tailnet_ip after `tailscale up`)
#   hooks.<domain>   → webhook ingress (funnel vs Lambda relay — still an open decision)

resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "GiTF — managed by infra/aws"
}

# Mail: the domain is attached to the existing purdonmoi.com Google
# Workspace (free additional domain) so factory@ghostinthefactory.com is an
# alias on an existing mailbox — no new subscription, no third-party
# forwarder.
resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain
  type    = "MX"
  ttl     = 3600
  records = ["1 smtp.google.com"]
}

resource "aws_route53_record" "spf" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain
  type    = "TXT"
  ttl     = 3600

  # SPF plus (when set) the Google site-verification token for the
  # Workspace add-domain flow — TXT values merge into one record set.
  records = concat(
    ["v=spf1 include:_spf.google.com ~all"],
    var.google_site_verification == null ? [] : [var.google_site_verification]
  )
}

resource "aws_route53_record" "factory" {
  count = var.factory_tailnet_ip == null ? 0 : 1

  zone_id = aws_route53_zone.main.zone_id
  name    = "factory.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [var.factory_tailnet_ip]
}
