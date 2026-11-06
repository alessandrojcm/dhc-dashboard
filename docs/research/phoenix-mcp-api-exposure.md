# Research — exposing the Phoenix API through an MCP server

**Research date:** 2026-10-28  
**Question:** How should DHC expose selected Phoenix capabilities through MCP, which Elixir implementation is suitable, does Jido work, and how should authentication and PII be protected?

## Recommendation

Build a **separate, narrow MCP adapter in `apps/phoenix`**, with reviewed tools that call the existing Phoenix domain/context read models and command boundaries. Do **not** auto-wrap the REST/OpenAPI surface and do not make Ecto schemas or generic REST request/response payloads MCP results.

For a new implementation, evaluate **ExMCP's maintained 1.x line**, with **1.7.3** as the version inspected here, as the leading Elixir candidate: it supplies Phoenix/Plug integration, Streamable HTTP and stdio, client and server support, and OAuth helpers. It is a community SDK, not an official MCP SDK. The official SDK roster contains no Elixir SDK. Pin and validate the chosen release during implementation; the current Hex documentation reports `ex_mcp` 1.7.3 and a maintained-1.x repository after a project rename. Its renamed v2 packages are release candidates, not the stable baseline recommended here. [MCP SDK roster][mcp-sdks] [ExMCP README][exmcp]

The first production increment should be **read-only and aggregate/minimized** (for example: operational counts or purpose-built, capability-gated workflow views), over authenticated remote Streamable HTTP. Add mutations only as individually named tools with narrow schemas, idempotency/confirmation semantics, audit records, and an MCP-client/user approval expectation. MCP tools are model-controlled; the protocol recommends a human able to deny calls and confirmation for sensitive operations. [MCP tools][mcp-tools]

This exposes selected **API capabilities**, not necessarily their literal HTTP endpoints. An in-process adapter avoids loopback HTTP and preserves the existing domain boundaries. It does **not** inherit router/controller checks or controller-side effects automatically: those must be deliberately preserved. For example, the report context is actor-free and relies on its route gate, while an inventory loan request attaches notifications in its controller. If literal REST proxying is required instead, design separate downstream credentials and a fixed operation allowlist; do not forward the incoming MCP token. [Report source][report] [Inventory controller][catalog-controller] [MCP authorization][mcp-auth]

## Protocol facts that shape the design

### Server versus client

An MCP **server** exposes tools, resources and prompts; an MCP **client** discovers/calls these from a host application. A server can offer just tools. DHC is considering the server role; it does not need an agent framework, an LLM, or an MCP client merely to expose DHC operations. The protocol's official SDK list has Tier 1 SDKs for TypeScript, Python, C#, Go, Rust and Ruby, but no Elixir entry. [MCP SDK roster][mcp-sdks]

Tools are the correct default for filtered operational queries and commands. The server must validate tool inputs, enforce access control, rate-limit calls and sanitize outputs. `tools/list` may vary by the credential on **each request**, so it can safely disclose only the tools that the current principal/scope may use. [MCP tools][mcp-tools]

Resources are application-driven context. A client/host may list, select, fetch, or automatically include them in model context; subscribed resources can send updates. Therefore do **not** publish person-, invitation-, payment-, reply-, or token-derived data as resources by default. If a resource is later justified, use opaque, non-sensitive URIs; authorize both listing and every read; make it short-lived/private; and do not offer subscriptions until the privacy/audit model covers continuous disclosure. Resource URIs and templates themselves can leak identifiers. [MCP resources][mcp-resources]

Prompts should not contain private records. Server-provided prompt text and tool/resource results are untrusted content from the model-security perspective; treat data obtained through tools or resources as data, never as instructions that can cause the adapter to expand authority or call a different tool.

### Transport

MCP standard transports are stdio and Streamable HTTP. **The current 2026-07-28 revision uses POST with JSON or request-scoped SSE responses; it removed the standalone GET stream, protocol-level sessions and the initialize handshake used by earlier revisions.** Earlier Streamable HTTP revisions supported GET/SSE and session IDs. ExMCP documents support for both eras, but the target clients must be tested explicitly. Origin validation is required, local loopback binding and authentication are recommended by the transport spec, and DHC should require authentication for its protected data. Stdio is suitable when the MCP client launches a local subprocess; MCP authorization says stdio should obtain credentials from the environment rather than use the HTTP OAuth flow. [MCP transports][mcp-transports] [Current HTTP binding][mcp-http] [ExMCP README][exmcp] [MCP authorization][mcp-auth]

Recommendation:

1. **Remote DHC deployment:** one dedicated HTTPS MCP endpoint, Streamable HTTP, not a blanket `/api` route; validate exact allowed origins and hosts; impose request/body/output/time/concurrency limits; disable legacy HTTP+SSE unless a required client truly needs it.
2. **Developer-local use:** prefer stdio or a loopback-only HTTP endpoint. Treat any process that can launch the server or read its environment as able to exercise the granted DHC identity. Never bind local HTTP to all interfaces by default.
3. Do not rely on MCP session IDs for identity. Every protected HTTP request needs authentication. The current protocol has no protocol-level sessions; if supporting an earlier revision, its sessions must be server-issued and bound to the authenticated identity. Application workflow state must have its own ownership/expiry checks. [Current HTTP binding][mcp-http] [ExMCP HttpPlug][exmcp-plug]

**Phoenix integration details:** mount the MCP Plug in a dedicated scope rather than assuming the existing JSON API pipeline is the transport boundary. ExMCP documents that router mounting sees `conn.body_params` after `Plug.Parsers`; strict body limits need an aligned parser limit or cached raw bytes. DHC currently caches raw bodies only for signed webhooks, not MCP. Also mount RFC 9728 metadata at the correct host-root well-known path: forwarding `/mcp` alone does not serve `/.well-known/oauth-protected-resource/mcp`. Configure explicit origin/host allowlists; CORS headers are not authentication. [ExMCP README][exmcp] [ExMCP HttpPlug][exmcp-plug] [Repository router][router] [Endpoint][endpoint] [Body reader][body-reader]

## Authentication and authorization recommendation

### Remote MCP: new bearer credentials, not the dashboard cookie

MCP authorization is optional at the protocol level, but **DHC should adopt its OAuth flow for protected remote access**. In that flow, MCP defines the server as an OAuth 2.1 protected resource and the client as an OAuth client. The server must expose RFC 9728 Protected Resource Metadata; tokens are sent only as `Authorization: Bearer`, never in a query string; and the server must validate expiry and that the token's audience is this MCP server. It must not accept a token issued to another resource or forward it to downstream services. OAuth clients use PKCE and a `resource` indicator. [MCP authorization][mcp-auth]

**Recommended DHC design (recommendation, not an established repo fact):** add a dedicated MCP authorization/grant model or an OAuth authorization-server integration which mints short-lived, audience-bound MCP access tokens. Map token subject to the existing DHC Principal, carry narrowly named MCP scopes, and re-evaluate DHC capabilities and resource ownership/assignment at every tool invocation. Revocation/deactivation and role changes must invalidate/reject MCP access just as DHC session changes do. Do not exchange or replay the browser `_dhc_session` cookie as an MCP bearer token.

This fits the repository's existing boundary: `DhcWeb.Plugs.RequireSession` authenticates only the signed `_dhc_session` cookie and projects an active principal plus capabilities; `Dhc.Auth.Capabilities` is the sole role-to-capability policy and has resource-aware owner/assignment checks. The existing JSON session response intentionally contains an email, roles and capabilities, so it is not an appropriate generic MCP identity/result object. [RequireSession source][require-session] [Capabilities source][capabilities] [Session renderer source][session-renderer]

Use scopes to reduce the *credential* blast radius (for example, a baseline read scope plus specific elevation scopes), but scopes do not replace DHC authorization. The MCP authorization specification recommends a minimal initial scope set and a precise `WWW-Authenticate` scope challenge for insufficient scope; it requires the server to return 401 for invalid/expired credentials and 403 for insufficient scope. [MCP authorization][mcp-auth]

**Unknown deployment fact:** this research found DHC's browser magic-link sessions and Discord OAuth, but no OAuth 2.1 authorization-server, issuer, signing-key, token-introspection, protected-resource-metadata, or client-registration deployment configuration. Those choices and which MCP clients must interoperate are prerequisites to selecting the OAuth implementation and deployment shape.

**OAuth implementation choices:** ExMCP's bearer-validation helpers are not a replacement for DHC login, consent and grant lifecycle. Reuse DHC's existing browser sign-in for the authorization/consent page, then issue separate MCP grants. If hosting the authorization server in Elixir, **Boruta** is a candidate provider core: its first-party docs describe Phoenix integration, authorization-code flow, PKCE, introspection and revocation. That is not proof of complete current MCP/OAuth 2.1 compliance: RFC 8707 resource/audience binding, RFC 9728 metadata, current client registration/discovery and redirect handling still need verification. An external authorization server is another option, but must integrate with the existing Principal directory rather than silently replacing it or enabling public signup; ADR 0009 requires Phoenix-owned identities and invitation-only membership. Do not use Discord access tokens as MCP access tokens. [ExMCP HttpPlug][exmcp-plug] [Boruta provider docs][boruta] [Authentication ADR][auth-adr] [MCP authorization][mcp-auth]

The effective permission is the **intersection** of the client's granted MCP scope, the tool's explicit data policy, and the Principal's **current** DHC capability/ownership/assignment. Derive acting Principal IDs server-side. A grant must never preserve a capability after the underlying DHC permission has been removed; define explicitly whether browser logout also revokes MCP grants, rather than assuming the existing session lifecycle does this automatically. These are proposed controls, not existing MCP features in this repository.

### Authorization must happen inside every tool

Each tool should:

1. authenticate the request and resolve a non-secret principal/grant;
2. validate the fixed JSON Schema input and size limits;
3. call `Dhc.Auth.Capabilities.authorize/3` with the existing named capability and, where needed, the loaded resource facts, rather than checking roles or trusting a caller-provided principal/resource identifier;
4. call an existing domain query/command boundary; and
5. project its result into a MCP-specific safe response.

Do not proxy an inbound MCP bearer token to Phoenix `/api`: MCP forbids token passthrough, and it would bypass the intended MCP audience boundary. Do not make an MCP tool a generic URL/method/body proxy, SQL executor, OpenAPI operation dispatcher, or schema serializer. Those designs expose every future REST endpoint by default, make parameter-based authorization easy to miss, and turn prompt-injected tool arguments into arbitrary API reachability.

## PII and data-minimization controls

### Tool allowlist and response contracts

Create an explicit source-controlled allowlist of tool modules. Each tool needs an input schema with `additionalProperties: false`, strict pagination and filter caps, an output schema, a sensitivity classification, required DHC capability/scope, and a dedicated projection. Return stable IDs or opaque handles only where a follow-up is genuinely needed; a handle is not authorization and must be re-authorized on every use. MCP's non-normative stateful-tool guidance recommends per-call authorization, opacity and an explicit handle lifetime. [MCP tools: stateful tools][mcp-tools]

Default response pattern:

- aggregate counts, status categories, dates/times, and narrowly defined operational facts;
- no direct Ecto struct serialization, no `Map.from_struct`, no raw problem/changeset dumping, no request headers/cookies, and no debug/raw upstream response field;
- no contact details, date of birth, guardian information, medical facts, payment/Stripe facts, raw inbound email/reply text, onboarding tokens/continuations, OAuth/provider subjects, session credentials, or full audit history unless a separately approved tool has a written necessity and its own authorization/projection tests;
- cap lists and text lengths; use server-side searching/filtering rather than returning a corpus for model-side filtering.

**For the requested no-PII default, omit person-level tools entirely**, even when the user could read those records in the dashboard. A later exception would change the privacy requirement and needs an explicit decision; it is not unlocked merely by granting an admin scope. Names removed or replaced by a UUID/handle do not make a person anonymous. Ireland's DPC and the European Commission distinguish pseudonymisation from anonymisation and explain that combinations of indirect identifiers can still identify someone. [DPC guidance][dpc] [European Commission explanation][ec-personal-data]

Concrete DHC boundaries and risks:

| Existing surface | MCP treatment proposed here |
|---|---|
| Member list/profile/current-user responses | Exclude: their renderer includes contact details and, in member records, birth dates, medical conditions, and guardian/next-of-kin information. [Member renderer][member-renderer] |
| Beginners' Workshop report | Candidate source for a **new** aggregate projection, not a PII-free pass-through. Small workshop/offer-round counts, dates and financial totals can reveal a person's circumstances when combined with other knowledge. Suppress/coarsen small cohorts and complementary totals, restrict filter combinations/time granularity, and consider repeated-query differencing before approval. No universal threshold proves anonymity. [Report source][report] [Report renderer][report-renderer] [DPC guidance][dpc] |
| Member inventory catalog | Useful closed-projection precedent: it cannot disclose borrower IDs, operator notes or container details. But labels/property text are still text, not a guarantee that nobody entered personal information. Prefer approved categories/enums or aggregate counts; review every exposed text field. [Catalog source][catalog] [Catalog renderer][catalog-renderer] |
| Intake reply text | Exclude. The existing `ReplyText.extract/1` redacts links/addresses but explicitly leaves names in the person's words; it is not a general PII remover. [ReplyText source][reply-text] |

Implement projections by constructing approved keys, not by deleting known-sensitive fields from a broad response. Validate nested output with closed schemas and fail closed on unexpected fields; cover **both** `structuredContent` and any duplicated text content, metadata, errors and resource links. Do not mirror sensitive arguments into `x-mcp-header`, which makes them visible to intermediaries. Regex/entity detection can be a secondary alarm, never the security boundary; neither a prompt saying "do not reveal PII" nor read-only access enforces this policy. [MCP tools][mcp-tools]

The controllable promise is **no server-origin personal business data in approved MCP outputs**, not that a user cannot type personal information into their own MCP client. Once data reaches a client/model provider, server-side redaction cannot recall it. Target clients, provider retention/training settings and data-processing arrangements need review before any personal-data exception; they are not established by this source-only research.

This recommendation is especially important because DHC's own sources deliberately establish safe/closed views for invitation acceptance and intake links, redact credential-bearing URLs, and separate member-facing from operator inventory read models. The router also contains public credential/token routes and webhook routes that must never become MCP tools. [Repository router][router] [Repository knowledge base][agents]

### Errors, logs and observability

Return a small closed error vocabulary (invalid input, not found/concealed, unavailable, denied) without echoing sensitive input or raw exception messages. Preserve existing concealment semantics: owner/assignment denial is `:not_found` in `Dhc.Auth.Capabilities`, not a signal that a record exists. [Capabilities source][capabilities]

Log tool name, outcome category, authorization/scope decision, time, correlation ID and a pseudonymous/internal actor reference only if operationally required. Do not log tool arguments/results, authorization headers, raw bearer tokens, cookies, resource URIs containing identifiers, or model prompt material. Review Sentry/OpenTelemetry capture and reverse-proxy access logs for the same fields. The existing session plug already records aggregate rejection telemetry without email or principal ID; use that precedent. [RequireSession source][require-session]

Any actor-linked audit trail remains personal data: keep it access-restricted with a retention policy, separate from model-visible output and general telemetry. Existing URL/email-job scrubbing is specialized, not evidence that arbitrary MCP bodies are scrubbed; add an MCP-specific observability policy rather than assuming today's filters cover it. Cache any authenticated results/tool lists by authorization identity and effective scope/data policy, or disable caching initially; never share a response across principals. [Endpoint][endpoint] [Sentry privacy boundary][sentry-privacy] [MCP tools][mcp-tools]

### Prompt injection and subscriptions

Assume model-visible results can contain hostile instructions. The model must not be able to use record text to expand tool selection, alter authorization, or call URLs supplied by a result. Keep tool descriptions imperative and narrowly scoped; avoid instructions such as "follow links" in returned text; encode results as bounded structured data. Require confirmation for any state-changing operation even if a client advertises a permissive annotation—tool annotations are not trusted security controls. [MCP tools][mcp-tools]

For sensitive future writes, a client-side "approved" flag is insufficient. Bind a server-validated confirmation to the Principal, tool, normalized complete arguments/target, expiry and idempotency key, preferably through the authenticated dashboard. Changed arguments require a new confirmation. Existing command/notification behavior must remain the owner of the action, including effects currently attached by HTTP adapters. This is a proposed action-binding design, not something MCP tool annotations provide.

Do not implement resources, resource templates, resource links, or subscriptions in v1. They broaden passive/contextual disclosure. If later needed, resource list/read and subscription setup/delivery must all authorize per principal; update notifications must be metadata-only and never carry sensitive changed content. Do not use `https://` resource URIs for protected data because the protocol reserves that scheme for data the client can fetch directly from the web. [MCP resources][mcp-resources]

## Elixir library survey (current evidence)

| Option | Verified capabilities | Assessment for DHC |
|---|---|---|
| **ExMCP** | Community library; documented Phoenix `ExMCP.HttpPlug`, server handler/DSL, client/server, Streamable HTTP, stdio and BEAM-local transports; docs claim current and legacy MCP revisions plus OAuth 2.1 helpers and conformance checks. The Plug documents origin/host checks, bearer OAuth configuration and session-to-authorization-identity binding. | **Leading implementation candidate.** Evaluate the actual pinned source/release and run MCP Inspector/conformance plus DHC authorization/PII tests. Its project migration/maintenance status means dependency ownership and upgrade monitoring must be explicit. [ExMCP README][exmcp] [ExMCP HttpPlug][exmcp-plug] |
| **Hermes MCP** | Community client/server library with Phoenix Streamable HTTP example; current docs show `hermes_mcp` 0.14.1. | Viable comparison candidate, but this research did not establish OAuth/resource-server support or protocol conformance evidence from its primary docs. Do not select it for a protected remote DHC endpoint without validating those features. [Hermes docs][hermes] |
| **EMCP** | Minimal server with Phoenix Streamable HTTP mounting, tools/resources/prompts, stdio, optional origin validation; current docs show 0.3.4. Its docs explicitly say unknown sessions are silently recreated by default unless configured otherwise, a deliberate deviation from the spec. | Useful small/local prototype candidate, not the preferred remote protected endpoint absent an independently verified OAuth/authn design and strict session setting. [EMCP docs][emcp] |
| **Jido / `jido_mcp`** | Jido itself is an OTP agent/workflow framework; AI is optional. `jido_mcp` did provide an explicit publish allowlist and a Plug bridge, but its own official docs say 2.0.0 is final, deprecated/retired, and will receive no feature, compatibility, security or dependency updates. It directs new protocol/server work to ExMCP. | **Do not add `jido_mcp` for new DHC work.** Jido is unnecessary for exposing tools. Use Jido only if DHC separately needs its agent/workflow runtime; keep the MCP authorization/projection boundary independent. [Jido source][jido] [Jido MCP deprecation][jido-mcp] |

Other community libraries exist (for example, NexusMCP and ConduitMCP), but were not recommended because the user asked for current primary-source assessment, and the three alternatives above supplied directly inspectable Phoenix-facing documentation. Absence from this table is not a security or maintenance verdict.

## Does Jido work?

**Technically, it worked as an adapter; strategically, no for new work.** Jido core is a real, active Elixir agent framework and does not require AI. Historical `jido_mcp` could expose an allowlisted set of Jido Actions over MCP and later used ExMCP underneath. But the package's first-party deprecation record says every published release is retired; there is no support window or future security/compatibility update; new MCP client/server/transport work belongs in ExMCP. Its suggested managed replacement (Jido Connect v3) was not public/stable at its deprecation date. [Jido source][jido] [Jido MCP deprecation][jido-mcp]

Thus: do not introduce Jido simply to "turn Phoenix REST into MCP." If a future DHC feature independently adopts Jido for durable agent orchestration, it may call reviewed DHC domain actions, but the MCP server must still have its own request authentication, DHC capability/ownership checks, PII projection, rate limits and tool allowlist.

## Implementation decision gates (before writing code)

1. Name the first 3–5 tools and a written data contract for each; reject the project if any need is stated only as "expose the API."
2. Decide target clients and whether DHC needs remote access, local developer access, or both; test their actual MCP protocol/OAuth support.
3. Choose an authorization server/token format and revocation strategy; verify audience, issuer, resource indicator, PKCE/client registration, metadata endpoints and exact redirect validation.
4. Define an MCP scope-to-DHC-capability mapping that starts read-only and preserves DHC owner/assignment checks.
5. Complete a data-protection review for every input, output, URI, error, log/trace field, tool description and subscription/event.
6. Add abuse limits, client/user confirmation expectations, audit retention, incident revocation, tests for negative authorization and projection absence, and Inspector/conformance/interoperability tests.

### Acceptance checks for an implementation

- Reject wrong issuer/audience, expired/revoked tokens, inactive Principals, removed capabilities/assignments and missing MCP scopes; conceal another person's resource.
- Reject guessed/replayed cross-principal handles and cursors; verify tool-list and response caches cannot cross identities.
- Populate synthetic nested sensitive-field canaries and assert they never appear in any result channel, error, URI, log or trace; reject schema additions until explicitly reviewed.
- Test small-cohort suppression and differencing/complementary totals, not just absence of `name`/`email` keys.
- Test invalid origins/hosts, oversized pre-parsed bodies, request/output/concurrency limits and the root metadata URL through the real mounting/proxy topology.
- Exercise each chosen client/protocol era; run pinned-library conformance tests without treating upstream self-reported results as DHC verification.
- Before enabling writes, test exact confirmation binding, changed arguments, retries/idempotency and parity with existing command effects.

**Research validation:** official protocol/library documentation and relevant local source were inspected; Markdown references/local paths and whitespace were checked. No dependency was installed, no library was compiled, and no application build/typecheck/test suite or deployed endpoint was exercised. Compatibility, OAuth-provider completeness, client interoperability and PII enforcement remain implementation gates, not claims of a working server. Only this research document was added; no runtime target or deployment was changed.

## Sources

Primary sources accessed 2026-10-28:

- [MCP official SDK roster][mcp-sdks]
- [MCP authorization specification][mcp-auth]
- [MCP Streamable HTTP and stdio transports][mcp-transports]
- [MCP tools specification][mcp-tools]
- [MCP resources specification][mcp-resources]
- [ExMCP 1.x README / maintained-source notice][exmcp] and [Phoenix `HttpPlug` reference][exmcp-plug]
- [Jido core repository README][jido] and [Jido MCP's official deprecation/migration guidance][jido-mcp]
- [Hermes MCP docs][hermes] and [EMCP docs][emcp]
- Repository sources: [router][router], [session plug][require-session], [capabilities][capabilities], [session renderer][session-renderer], and [authentication ADR][auth-adr].

[mcp-sdks]: https://modelcontextprotocol.io/docs/2026-07-28/sdk.md
[mcp-auth]: https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/index.md
[mcp-transports]: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports.md
[mcp-http]: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http.md
[mcp-tools]: https://modelcontextprotocol.io/specification/2026-07-28/server/tools.md
[mcp-resources]: https://modelcontextprotocol.io/specification/2026-07-28/server/resources.md
[exmcp]: https://hexdocs.pm/ex_mcp/readme.html
[exmcp-plug]: https://hexdocs.pm/ex_mcp/ExMCP.HttpPlug.html
[jido]: https://github.com/agentjido/jido
[jido-mcp]: https://hexdocs.pm/jido_mcp/deprecation_plan.html
[hermes]: https://hexdocs.pm/hermes_mcp/readme.html
[emcp]: https://hexdocs.pm/emcp/readme.html
[router]: ../../apps/phoenix/lib/dhc_web/router.ex
[require-session]: ../../apps/phoenix/lib/dhc_web/plugs/require_session.ex
[capabilities]: ../../apps/phoenix/lib/dhc/auth/capabilities.ex
[session-renderer]: ../../apps/phoenix/lib/dhc_web/controllers/auth_session_json.ex
[auth-adr]: ../adr/0009-phoenix-owns-authentication.md
[agents]: ../../AGENTS.md
[boruta]: https://hexdocs.pm/boruta/readme.html
[dpc]: https://www.dataprotection.ie/en/dpc-guidance/anonymisation-pseudonymisation
[ec-personal-data]: https://commission.europa.eu/law/law-topic/data-protection/data-protection-explained_en
[report]: ../../apps/phoenix/lib/dhc/beginners_workshops/report.ex
[report-renderer]: ../../apps/phoenix/lib/dhc_web/controllers/beginners_workshop_report_json.ex
[catalog]: ../../apps/phoenix/lib/dhc/inventory/member_catalog.ex
[catalog-controller]: ../../apps/phoenix/lib/dhc_web/controllers/inventory_catalog_controller.ex
[catalog-renderer]: ../../apps/phoenix/lib/dhc_web/controllers/inventory_catalog_json.ex
[member-renderer]: ../../apps/phoenix/lib/dhc_web/controllers/members_json.ex
[reply-text]: ../../apps/phoenix/lib/dhc/beginners_workshops/intake_replies/reply_text.ex
[endpoint]: ../../apps/phoenix/lib/dhc_web/endpoint.ex
[body-reader]: ../../apps/phoenix/lib/dhc_web/cache_body_reader.ex
[sentry-privacy]: ../../apps/phoenix/lib/dhc_web/sentry_privacy.ex
