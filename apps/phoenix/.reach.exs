# Reach architecture policy — https://hexdocs.pm/reach
#
# Enforced by `mix reach.check --arch`, wired into the `precommit` Mix alias
# and runnable ad hoc via `mise run phx-reach`. Findings not present in
# .reach-baseline.json fail the build; regenerate the baseline only for known
# transitional findings:
#
#   mix reach.check --arch --write-baseline .reach-baseline.json
[
  layers: [
    web: "DhcWeb.*",
    domain: "Dhc.*",
    data: "Dhc.Repo"
  ],
  deps: [
    forbidden: [
      # Contexts and workers must not depend on the web layer. DhcWeb.Endpoint
      # is the documented exception: PubSub broadcasts and endpoint config are
      # shared infrastructure (e.g. lib/dhc/notifications/broadcaster.ex).
      {:domain, :web,
       except_edges: [
         {"Dhc.*", "DhcWeb.Endpoint"}
       ]},
      # The Repo must not depend on the web layer.
      {:data, :web},
      # Controllers/plugs go through Phoenix contexts; direct Repo access from
      # the web layer is forbidden. The magic-link rate limiter is the single
      # documented seam: an atomic upsert on auth_rate_limit_windows that has
      # no context home (lib/dhc_web/plugs/magic_link_rate_limit.ex). The
      # vendored idempotency Ecto store is likewise a storage adapter at the
      # web boundary, not a domain context.
      {:web, :data, except: ["DhcWeb.Plugs.MagicLinkRateLimit", "IdempotencyPlug.EctoStore"]}
    ]
  ],
  calls: [
    forbidden: [
      # Stripe goes through the generated Dhc.Stripe.Operations.* API only;
      # the raw client escape hatch is reserved for debugging the client
      # boundary itself (docs/agents/anti-patterns.md).
      {"Dhc.*", ["Dhc.Stripe.Client.request"], except: ["Dhc.Stripe.Client"]},
      # Nostrum stays behind the Dhc.Discord adapter boundary
      # (docs/agents/critical-patterns.md, "Discord Server REST").
      {"Dhc.*", ["Nostrum.*"], except: ["Dhc.Discord.*"]},
      # Req is the sanctioned HTTP client (apps/phoenix/AGENTS.md); no
      # HTTPoison/Tesla/:httpc in app code.
      {"Dhc.*", ["HTTPoison.*", "Tesla.*", ":httpc.request"]},
      # IO.puts belongs to Mix tasks and release scripting, not app code.
      # Credo's IoPuts check is disabled in this repo, so this fills that gap.
      {"Dhc.*", ["IO.puts"], except: ["Dhc.Release"]}
    ]
  ],
  checks: [
    # Pin analysis to lib/ so the baseline stays valid regardless of MIX_ENV
    # (the precommit alias runs reach.check under MIX_ENV=test while day-to-day
    # runs use dev). Explicit paths carry no Mix-environment identity.
    source_paths: ["lib"],
    baseline: ".reach-baseline.json"
  ]
]
