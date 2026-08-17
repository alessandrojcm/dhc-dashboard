# ALE-225 — Elixir Discord library comparison: Nostrum vs hand-rolled client

**Research date:** 2026-08-17  
**Question:** Which library should a new holistic `Dhc.Discord` module use for bot-token Discord guild operations — Nostrum, or a thin hand-rolled client using the HTTP stack the repo already has?

> **Supersession note (2026-08-17, ALE-226):** The recommendation below (hand-rolled
> Req client) is **reversed to Nostrum**. The bot is now a permanent Phoenix runtime
> capability reusing the existing DHC bot application, and Discord functionality is
> planned to grow beyond Discord Doctor's REST calls, so a maintained full client with
> gateway support earns its runtime cost. The REST findings (endpoints, privileged
> intent, rate limits, Elixir/OTP compatibility) remain valid. Amendment recorded on
> ALE-225 in Linear.

## Findings

### 1. Local prior art

The repository already has prior research on Discord operations in `docs/research/`:

- **ALE-203** established the need for `GUILD_MEMBERS` privileged intent and bot-token authentication for roster operations
- **ALE-210** documented the controlled, one-shot roster export script pattern using `DISCORD_ROSTER_BOT_TOKEN`

The existing HTTP stack uses **Req** (`~> 0.7.2`) via Finch/Mint, as seen in `apps/phoenix/mix.exs:79` and `apps/phoenix/lib/dhc/stripe/client.ex`. The Stripe client demonstrates the established pattern: custom auth headers, JSON handling, and error normalization.

Sources:
- [ALE-203](./ale-203-discord-oauth-guild-roster-capabilities.md)
- [ALE-210](./ale-210-existing-bot-roster-access-contract.md)
- `apps/phoenix/lib/dhc/stripe/client.ex`

### 2. Nostrum analysis

#### Current status

Nostrum is actively maintained (latest stable: **v0.10.4**, released 2025-03-02). It provides:
- Clean REST API implementation with automatic ratelimiting
- Documented structs for API objects
- Configurable local data caches (gateway-fed)

Source: [Nostrum Hex package](https://hex.pm/packages/nostrum)

#### Elixir/OTP compatibility

The repo uses Elixir 1.20 and OTP 29 (`.mise.toml:14-15`). Nostrum v0.10.4 is compatible with these versions.

Source: `.mise.toml`

#### Gateway requirement

**Critical finding:** Nostrum can run REST-only. According to the official documentation:

> "To utilize only the REST portion of the API, manually start the ratelimiter by calling `Nostrum.Api.Ratelimiter.start_link/1`. Alternatively, if you do not wish to start Nostrum, you can set `runtime: false` in the dependency options."

The ratelimiter is the only required process for REST-only operation.

Source: [Nostrum REST-only guide](https://github.com/kraigie/nostrum/blob/master/guides/intro/api.md)

#### Required processes

For REST-only usage, only the `Nostrum.Api.Ratelimiter` needs to be started. No gateway shards, no consumer processes, no cache processes.

The full supervision tree (when using gateway) includes:
- `Nostrum.Bot` supervisor
- Shard processes
- Cache processes (ETS-based by default)
- Ratelimiter state machine

Source: `Nostrum.Bot` documentation

#### Rate limiting

Nostrum implements a ratelimiter state machine (`Nostrum.Api.Ratelimiter`) that:
- Parses `X-RateLimit-*` headers from responses
- Tracks per-route buckets
- Handles 429 responses with `Retry-After`
- Manages global rate limits (50 req/s for bots)

This works without the gateway connection — all requests flow through the ratelimiter regardless.

Source: [Nostrum API Ratelimiting](https://github.com/kraigie/nostrum/blob/master/guides/intro/api.md)

#### Coverage of required endpoints

Nostrum provides direct functions for all 4 required operations:

| Operation | Nostrum Function | Endpoint |
|-----------|------------------|----------|
| List guild members | `Nostrum.Api.Guild.members/2` | `GET /guilds/{guild.id}/members` |
| Add member via OAuth | `Nostrum.Api.Guild.add_member/3` | `PUT /guilds/{guild.id}/members/{user.id}` |
| Kick member | `Nostrum.Api.Guild.kick_member/3` | `DELETE /guilds/{guild.id}/members/{user.id}` |
| Create invite | `Nostrum.Api.Channel.create_invite/2` | `POST /channels/{channel.id}/invites` |

The `add_member/3` function accepts `:access_token` (OAuth token) and optional `:nick`, `:roles`, etc. as documented.

Sources:
- [Nostrum.Api.Guild hexdocs](https://hexdocs.pm/nostrum/Nostrum.Api.Guild.html)
- [Discord Add Guild Member docs](https://docs.discord.com/developers/resources/guild#add-guild-member)

#### Audit log reason header

Nostrum supports the `X-Audit-Log-Reason` header via an optional `reason` parameter on kick and other mutating operations:

```elixir
Guild.kick_member(guild_id, user_id, "Violation of code of conduct")
```

Source: Nostrum.Api.Guild source code

### 3. Hand-rolled option analysis

#### What it would look like

A thin client over the existing `Req`-based stack would need to implement:

1. **Authentication**: `Authorization: Bot <token>` header
2. **Request building**: JSON bodies, query params
3. **Response handling**: JSON decoding, error normalization
4. **Rate limit handling**: Parse `X-RateLimit-*` headers, respect `Retry-After`

Example structure (similar to `Dhc.Stripe.Client`):

```elixir
defmodule Dhc.Discord.ApiClient do
  def list_members(guild_id, opts \\ []) do
    Req.get(
      discord_url("/guilds/#{guild_id}/members"),
      headers: bot_auth_header(),
      params: [limit: opts[:limit] || 1000, after: opts[:after]]
    )
  end
  
  # ... similar for add_member, kick, create_invite
end
```

#### Rate limit handling required

Discord's rate limiting requires:

- **Per-route buckets**: Track `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset-After`, `X-RateLimit-Bucket`
- **429 handling**: Read `Retry-After` header and back off
- **Global limit**: 50 requests/second across all endpoints
- **Invalid request limit**: 10,000 requests/10min resulting in 401/403/429 gets IP banned for ~1 hour

Implementing a proper bucket-aware rate limiter is non-trivial. A minimal implementation could:
- Use `Req` with `retry: :transient` for automatic retries
- Track 429s manually
- Accept occasional 429s at club scale (~1 roster request, occasional kicks/invites)

At DHC scale (one-time roster import, occasional member operations), rate limits are unlikely to be hit. The `List Guild Members` endpoint has generous limits (1000 members/page, relatively high per-route limit).

Source: [Discord Rate Limits documentation](https://docs.discord.com/developers/topics/rate-limits)

#### Dependencies

The hand-rolled option requires **no new dependencies** — uses existing `Req`.

### 4. Cache analysis

#### Nostrum's cache

Nostrum's caches (including `MemberCache`) are **gateway-fed**. From the documentation:

> "In order to use this cache, you must enable the `:guild_members` intent, and you must also enable the `request_guild_members: true` configuration option."

For REST-only usage, Nostrum's caches would remain empty/irrelevant.

Source: [Nostrum.Cache.MemberCache](https://hexdocs.pm/nostrum/Nostrum.Cache.MemberCache.html)

#### Hand-rolled cache options

For a short-TTL in-memory guild roster cache, options include:

1. **Plain ETS**: Direct table management, no dependencies
2. **Cachex**: Not currently in `mix.lock` — would be a new dependency
3. **GenServer state**: Simple but less efficient for lookups

The existing dependencies do not include Cachex or similar caching libraries. Only `finch`, `req`, and standard library options are available.

Source: `apps/phoenix/mix.lock`

### 5. Comparison summary

| Factor | Nostrum | Hand-rolled |
|--------|---------|-------------|
| **New dependencies** | 1 (Nostrum + transitive deps) | 0 |
| **Lines of code** | ~0 (library handles it) | ~200-400 |
| **Rate limit handling** | Built-in, battle-tested | Must implement |
| **API coverage** | Complete Discord API | Only what we implement |
| **Type safety** | Structs for all API objects | Manual maps/structs |
| **Maintenance** | Library maintained | Team maintains |
| **Gateway coupling** | Can run REST-only | N/A (no gateway) |
| **Process overhead** | 1 ratelimiter process | 0 (stateless Req) |
| **Audit log support** | Built-in | Must implement header |
| **Invite operations** | `Nostrum.Api.Channel.create_invite/2` | Manual implementation |
| **Add member OAuth** | `Nostrum.Api.Guild.add_member/3` | Manual implementation |

### 6. Recommendation

**Use a hand-rolled Req-based client** for the holistic `Dhc.Discord` module.

#### Rationale

1. **No gateway requirement**: The module needs only 4 REST endpoints. Nostrum's full feature set (gateway, caching, voice, etc.) is unnecessary overhead.

2. **Rate limits manageable at DHC scale**: With ~1 roster request (paginated, 1000 members/page) and occasional kicks/invites, hitting Discord rate limits is unlikely. A minimal implementation with `Req`'s built-in retry handling is sufficient.

3. **No new dependencies**: Avoids adding Nostrum's transitive dependency tree (Gun, Mint, etc.) to the project.

4. **Alignment with existing patterns**: The `Dhc.Stripe.Client` already demonstrates the Req-based HTTP client pattern. A `Dhc.Discord.Client` would follow the same conventions.

5. **Simplicity**: For 4 endpoints, implementing thin wrappers around `Req.request/1` is straightforward and easier to understand/debug than a full library.

6. **Cache is separate concern**: A short-TTL roster cache can be implemented with plain ETS in `Dhc.Discord.GuildRosterCache` without needing Nostrum's gateway-fed caching system.

#### Implementation sketch

```elixir
defmodule Dhc.Discord.Client do
  @moduledoc "Thin wrapper over Req for Discord Bot API operations."
  
  defp bot_token, do: Application.fetch_env!(:dhc, :discord_bot_token)
  
  defp base_req do
    Req.new(
      base_url: "https://discord.com/api/v10",
      headers: [{"authorization", "Bot #{bot_token()}"}],
      decode_body: true
    )
  end
  
  def list_members(guild_id, opts \\ []) do
    Req.get(base_req(),
      url: "/guilds/#{guild_id}/members",
      params: [limit: opts[:limit] || 1000] ++ if(opts[:after], do: [after: opts[:after]], else: [])
    )
  end
  
  def add_member(guild_id, user_id, access_token, opts \\ []) do
    body = Map.merge(%{access_token: access_token}, Map.new(opts))
    Req.put(base_req(),
      url: "/guilds/#{guild_id}/members/#{user_id}",
      json: body
    )
  end
  
  def kick_member(guild_id, user_id, reason \\ nil) do
    Req.delete(base_req(),
      url: "/guilds/#{guild_id}/members/#{user_id}",
      headers: if(reason, do: [{"x-audit-log-reason", reason}], else: [])
    )
  end
  
  def create_invite(channel_id, opts \\ []) do
    Req.post(base_req(),
      url: "/channels/#{channel_id}/invites",
      json: Map.new(opts)
    )
  end
end
```

#### Rate limit mitigation

- Use `Req` with `retry: :transient` for automatic retry on 5xx and 429
- Log 429 responses with `Retry-After` for observability
- At DHC scale (~100-200 members), a single roster fetch is 1 request; kicks/invites are rare

#### Cache recommendation

For the short-TTL guild roster cache, implement with **plain ETS**:

```elixir
defmodule Dhc.Discord.GuildRosterCache do
  use GenServer
  
  @ttl_seconds 300
  
  def get(guild_id) do
    case :ets.lookup(:discord_roster_cache, guild_id) do
      [{^guild_id, roster, expires}] when expires > System.monotonic_time(:second) ->
        {:ok, roster}
      _ ->
        :miss
    end
  end
  
  def put(guild_id, roster) do
    expires = System.monotonic_time(:second) + @ttl_seconds
    :ets.insert(:discord_roster_cache, {guild_id, roster, expires})
  end
end
```

This avoids adding Cachex or other dependencies while providing the required caching behavior.

---

**Sources cited:**
1. [Nostrum Hex package](https://hex.pm/packages/nostrum)
2. [Nostrum REST-only API guide](https://github.com/kraigie/nostrum/blob/master/guides/intro/api.md)
3. [Nostrum.Api.Guild hexdocs](https://hexdocs.pm/nostrum/Nostrum.Api.Guild.html)
4. [Discord Rate Limits documentation](https://docs.discord.com/developers/topics/rate-limits)
5. [Discord Guild Resource - Add Guild Member](https://docs.discord.com/developers/resources/guild#add-guild-member)
6. [Nostrum.Cache.MemberCache documentation](https://hexdocs.pm/nostrum/Nostrum.Cache.MemberCache.html)
