# Alchemy.run for this project's infrastructure

**Research date:** 2026-10-21  
**Short answer:** **Yes for Cloudflare IaC, with a migration and maturity warning.** Alchemy has first-party Cloudflare resources for every category in the question, and an official SvelteKit-to-Workers integration. It can also manage Fly resources, but it is **not a drop-in replacement for this repository's Phoenix `fly deploy` release process**: Phoenix is Elixir, while Alchemy's Fly `Service` is an Effect/Node service. Retain or deliberately reimplement the Docker build, release command, and Ecto migration steps if considering Alchemy for Fly.

Alchemy's current 2.x line is still published as `2.0.0-beta` (the official October 12, 2026 release is beta.83). Its surface is moving quickly and the release notes document breaking changes. Treat a production adoption as a spike/pilot with pinned versions, not an assumed low-risk tooling swap. [Alchemy beta.83 release](https://alchemy.run/blog/2026-10-12-beta-83/) · [Alchemy beta.77 breaking changes](https://alchemy.run/blog/2026-09-08-beta-77/)

## Answers at a glance

| Question | Answer | Qualification |
| --- | --- | --- |
| Can Alchemy meet the Cloudflare IaC need? | **Yes** | TypeScript/Effect stacks; it plans, reconciles, tracks state, and can manage the Worker and related platform resources. |
| Does it cover every listed resource category? | **Yes** | See the concrete resource types and boundaries below. Durable Objects are Worker-hosted classes, not a separate standalone account resource. |
| Can it adopt deployed resources? | **Yes, conditionally** | There is no generic Terraform-style `import ADDRESS ID` command. Adoption depends on each provider's `read` implementation/identity lookup; an unowned conflict requires explicit opt-in. Adoption is followed by reconciliation, not merely state-file insertion. |
| Does it detect drift? | **Yes** | `alchemy drift` re-reads deployed resources; `--repair` converges them to the last persisted desired state. Resource coverage depends on providers being able to read the live resource. |
| Does it fit this monorepo? | **Yes** | Alchemy documents monorepos and supports pnpm CI. It also has an official Cloudflare SvelteKit resource. The existing SvelteKit adapter/config/deploy workflow would need a deliberate integration change. |
| Can it manage both Cloudflare and Fly? | **Partly** | Both providers can be composed in an Alchemy Stack, but the stock Fly `Service` targets Alchemy's JS/Effect runtime. Existing Phoenix-on-Fly requires custom image/Machine handling and an explicit replacement for the current release/migration path. |

## Component coverage

The Cloudflare overview links first-party guides for Workers, Durable Objects, D1, KV, R2, Queues, Workflows, Email, and Zones/DNS. Its API reference is grouped by provider and lists these resource namespaces. [Cloudflare overview](https://alchemy.run/cloudflare) · [Alchemy API reference index](https://alchemy.run/providers)

| Need | Alchemy support | Resource/API shape | Notes for this repository |
| --- | --- | --- | --- |
| Workers | **Yes** | `Cloudflare.Worker` | First-class deployable Worker resource; bundles code, deploys it, configures bindings/assets, and supports SvelteKit via `Cloudflare.Website.SvelteKit`. [Workers guide](https://alchemy.run/cloudflare/compute/workers) · [SvelteKit guide](https://alchemy.run/cloudflare/frontend/sveltekit) |
| Durable Objects | **Yes** | `Cloudflare.DurableObject` class/binding on a Worker | They are hosted by a Worker and include class migrations/bindings. Existing classes can be adopted with the Worker; on the adopting deploy the binding/class names must match the already deployed class. [DO guide](https://alchemy.run/cloudflare/compute/durable-objects) · [Worker reference: adopting existing DO](https://alchemy.run/providers/cloudflare/workers#durableobject-adopting-an-existing-durable-object) |
| R2 buckets | **Yes** | `Cloudflare.R2.Bucket` | Bucket config, domains, lifecycle/CORS/locks, and typed Worker bindings are covered. [R2 reference](https://alchemy.run/providers/cloudflare/r2) |
| D1 databases | **Yes** | `Cloudflare.D1.Database` | Supports migration application and binding. Existing Wrangler/Drizzle migration history has a documented one-way adoption into Alchemy's migration bookkeeping; that is specifically database migration-history handling, not proof of universal resource import. [D1 guide](https://alchemy.run/cloudflare/data/d1) · [D1 reference](https://alchemy.run/providers/cloudflare/d1) |
| KV namespaces | **Yes** | `Cloudflare.KV.Namespace` | Namespace provisioning and Worker bindings are first class. [KV guide](https://alchemy.run/cloudflare/data/kv) · [KV reference](https://alchemy.run/providers/cloudflare/kv) |
| Queues | **Yes** | `Cloudflare.Queues.Queue`, `Consumer`, `Subscription` | Queue, producer/consumer wiring, and event subscriptions are covered. [Queues guide](https://alchemy.run/cloudflare/messaging/queues) · [Queues reference](https://alchemy.run/providers/cloudflare/queues) |
| Workflows | **Yes** | `Cloudflare.Workflow` / `Cloudflare.Workflows` | Workflow class registration, bindings, schedules, and instance operations are documented. The class runs on a Worker. [Workflows guide](https://alchemy.run/cloudflare/compute/workflows) · [Workflows reference](https://alchemy.run/providers/cloudflare/workflows) |
| Email Routing | **Yes** | `Cloudflare.Email.Routing`, `Rule`, `CatchAll`, `Address` | Covers enabling routing on a zone, verified forwarding addresses, rules/catch-all, and handing inbound mail to a Worker. It is not the same product as Cloudflare Email Security (some latter resources are Enterprise-gated). [Email guide](https://alchemy.run/cloudflare/email) · [Email reference](https://alchemy.run/providers/cloudflare/email) |
| DNS / Zone configuration | **Yes** | `Cloudflare.Zone.Zone`, `Cloudflare.DNS.Record`, zone settings/DNSSEC | Zones, individual DNS records, DNSSEC, and zone settings are resources. Zones and records have explicit adoption safeguards. [Domains & DNS guide](https://alchemy.run/cloudflare/networking/domains) · [DNS reference](https://alchemy.run/providers/cloudflare/dns) · [Zone reference](https://alchemy.run/providers/cloudflare/zone) |
| Hyperdrive (also used here) | **Yes** | `Cloudflare.Hyperdrive.Connection` | First-party resource; it can bind to an external Postgres origin. This is directly relevant to the current Worker config. [Hyperdrive guide](https://alchemy.run/cloudflare/data/hyperdrive) · [Hyperdrive reference](https://alchemy.run/providers/cloudflare/hyperdrive) |

### What this repo currently declares

The request's list is broader than the resources currently visible in `apps/web/wrangler.jsonc`. That config declares the `dhc-dashboard` Worker, static assets, a Hyperdrive binding, vars, and the `dhc-email-assets` R2 binding; it does **not** declare D1, KV, Queue, Workflow, Durable Object, Email Routing, Zone, or DNS resources there. This is a config-file observation, not a claim that no such resources exist elsewhere in the Cloudflare account. [Repository Wrangler config](../../apps/web/wrangler.jsonc)

The existing frontend is SvelteKit 3 with `@sveltejs/adapter-cloudflare`, and its production deploy is a Wrangler action run from `apps/web`. Alchemy's official `Cloudflare.Website.SvelteKit` is relevant, but that guide says Alchemy injects its own adapter and replaces a declared adapter, so plan a framework/deploy integration change rather than just swapping the CLI command. [Web package](../../apps/web/package.json) · [Current deploy workflow](../../.github/workflows/deploy-master.yml) · [Alchemy SvelteKit integration](https://alchemy.run/cloudflare/frontend/sveltekit)

## Existing resources: adoption, state, and drift

### Adoption model

Alchemy's core operation is a provider `read` when a declared resource has no state. If `read` finds nothing, normal create proceeds. If it finds a resource it recognizes as belonging to this stack/stage/logical ID, it can recover/adopt it silently. If it finds a resource but cannot prove ownership, the provider returns `Unowned`; Alchemy refuses by default and `alchemy deploy --adopt` (or a scoped `adopt(true)`) authorizes takeover. `read` is provider-implemented and optional, so this is not a blanket guarantee that every resource type in every Cloudflare API can be imported by arbitrary ID. [Provider `read` and ownership contract](https://alchemy.run/infrastructure-as-code/provider/#read) · [Adopting Resources guide](https://alchemy.run/cli/adopting-resources/) · [Resource lifecycle: adoption](https://alchemy.run/infrastructure-as-code/resource-lifecycle/#adoption)

**No generic import command:** the documented workflow is to declare the resource with the intended logical ID and identifying props, then plan/deploy with adoption enabled when needed. This differs from `terraform import RESOURCE_ADDRESS ID`; inspect the resource-specific reference/source for how Alchemy identifies it before adopting.

### Safe first-adoption workflow

1. **Inventory and pin physical identities.** Write the stack so each resource lookup resolves to the actual deployed Worker/resource (explicit Worker name, zone name/ID, etc.). For existing Worker Durable Objects, preserve binding and class names on the adoption deploy.
2. **Choose a state backend and stage before touching production.** A new logical ID, stack, or stage is a different state address and may make the existing object appear to be a foreign collision—or create a second resource if the provider's identity doesn't match.
3. **Run a read-only plan with takeover enabled:** `alchemy plan --stage prod --adopt --detailed` (using the actual config path). Review every create/update/replace/delete. A plan is not a live drift read, but it will show intended input changes and adoption conflicts. [Plan command](https://alchemy.run/cli/plan/)
4. **Deploy with `--adopt` only after review.** Adoption does not mean "record current resource and leave it untouched": the provider reconciles it to the declared props. For a Worker this can update the script and bindings; for DNS/email it can alter routing/config.
5. **Protect valuable resources.** Set appropriate `retain()` policies for irreplaceable resources before any cleanup/deletion plan; an omitted declared resource is otherwise eligible for deletion. R2 deletion can fail on a non-empty bucket; Alchemy documents `forceDestroy` for deliberately disposable contents. [Removal policy and lifecycle](https://alchemy.run/infrastructure-as-code/resource-lifecycle/#removal-policy) · [R2 bucket deletion](https://alchemy.run/providers/cloudflare/r2#bucket-deleting-a-bucket)

### Examples and important differences

- **Worker + Durable Objects:** Alchemy explicitly documents adopting a Wrangler/dashboard/API-created Worker via `adopt(true)`. A foreign Worker lacks Alchemy ownership tags, so `--adopt` is required. On that first deploy a DO binding maps to its existing class by binding name; the class name must match. Rename only in a later deployment. [Worker reference, adoption](https://alchemy.run/providers/cloudflare/workers#durableobject-adopting-an-existing-durable-object)
- **Zones, records, and routes:** existing zones/records/routes are explicitly treated as unowned and require opt-in. DNS record matching uses `(name,type)` and can be ambiguous when multiple records share those fields; declaration must match `content`/`priority` exactly to identify one. [Domains & DNS](https://alchemy.run/cloudflare/networking/domains) · [Custom domains & routes](https://alchemy.run/cloudflare/networking/custom-domains)
- **Workflows:** docs explicitly say an existing Workflow has no ownership marker; retain its physical `workflowName` and opt in with `--adopt`. The fixed name is account-global rather than stage-scoped. [Workflows reference](https://alchemy.run/providers/cloudflare/workflows#workflow-defining-a-workflow)
- **D1 migration history:** databases previously migrated with Wrangler or Drizzle can carry their applied migration history forward into Alchemy's migration table; old history is left frozen. That helps avoid replaying already-applied migrations. [D1 migrations](https://alchemy.run/cloudflare/data/d1#migrations)
- **Other resources:** generic behavior is provider-specific. Confirm that the concrete `read` supports lookup/adoption and inspect provider-specific reconciliation before taking over R2/KV/Queues/Email resources. The framework's own docs distinguish resources that have ownership tags from resources with no ownership marker; don't infer importability solely from a resource appearing in the API reference. [Provider contract](https://alchemy.run/infrastructure-as-code/provider/#read)

### State and drift

- **State is separate from the cloud API.** It is keyed by stack, stage, namespace, and logical resource ID; it stores input props, output attributes, instance identity, and lifecycle status. Local default is `.alchemy/` (gitignore it). [State Store](https://alchemy.run/state-store/)
- **Team/CI state:** `Cloudflare.state()` stores state in an Alchemy Worker backed by a Durable Object with SQLite, with token/encryption material in Cloudflare Secrets Store; first use bootstraps those supporting resources. Alchemy also documents Postgres/custom state stores. This is useful for CI but means adopting it entails extra Cloudflare resources and permission requirements. [Cloudflare state store and bootstrap](https://alchemy.run/state-store/#cloudflare-state-store)
- **Drift detection:** `alchemy drift` re-observes deployed resources and reports drifted/missing resources. `alchemy drift --repair` restores them to the last persisted deployment state, not necessarily new code that has not yet been deployed. Re-run `deploy` to apply new code. [Drift command](https://alchemy.run/cli/drift/)
- **Command naming moved:** an older beta release described `alchemy sync`; beta.77 renamed this to `alchemy drift --repair`. Use the current CLI docs, not old `sync` snippets. [Historical beta.61 `sync`](https://alchemy.run/blog/2026-07-08-beta-61/) · [beta.77 command migration](https://alchemy.run/blog/2026-09-08-beta-77/)

## Model, Wrangler comparison, and authentication

### IaC model

Alchemy is **TypeScript**, with resource declarations executed as an Effect `Alchemy.Stack`; it is not declarative YAML. Providers implement resource read/diff/reconcile/delete, Alchemy builds a dependency plan, displays it, then applies it. Outputs from one resource can feed another. [What is Alchemy?](https://alchemy.run/what-is-alchemy/) · [Provider and plan/apply model](https://alchemy.run/infrastructure-as-code/provider/)

Minimal Cloudflare shape:

```ts
import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import * as Effect from "effect/Effect";

export default Alchemy.Stack(
  "DhcDashboard",
  { providers: Cloudflare.providers(), state: Cloudflare.state() },
  Effect.gen(function* () {
    const bucket = yield* Cloudflare.R2.Bucket("EmailAssets");
    // Declare the Worker/SvelteKit Website and its bindings here too.
    return { bucketName: bucket.bucketName };
  }),
);
```

Use the existing physical name only after verifying the resource's identity/adoption semantics. The snippet illustrates the stack form, not a production-ready repo migration.

### Alchemy vs standard Wrangler

| | Alchemy | Wrangler |
| --- | --- | --- |
| Primary config | TypeScript stack; cross-resource graph and outputs | `wrangler.jsonc` / TOML; Worker-centric source-of-truth config |
| Build/deploy | Stack plan then provider reconcile; Alchemy can build/deploy Workers and has `Website.SvelteKit` integration | Build/deploy Worker with commands such as `wrangler dev` / `wrangler deploy`; existing repo uses `cloudflare/wrangler-action` |
| Resource creation | Resource providers manage lifecycle; many Cloudflare products have their own resource types | Wrangler can auto-provision selected bindings (currently KV, R2, D1, Queues and others) when IDs/names omitted; it can write generated IDs back to local config. The Cloudflare docs say IDs may remain dashboard-only when deployment runs from CI without local config update. |
| State / plan | Explicit persisted stack state, plan, adoption, and drift/repair | Config-centric Worker workflow; CLI has per-product commands (e.g., `wrangler d1 create/list/migrations`) rather than Alchemy's one multi-resource stack state/plan model |
| Breadth | Can combine Cloudflare with other supported/custom provider layers | Cloudflare Workers Developer Platform focus |

Cloudflare explicitly recommends treating Wrangler config as the source of truth for Worker configuration, and documents automatic provisioning for selected resource bindings. So Wrangler is already a useful resource-as-config/deploy workflow for the app; Alchemy's incremental value is a graph and lifecycle/state/drift layer across separately managed resources. These tools can coexist, but **do not let both own/reconcile the same Worker or resource**. [Wrangler configuration and automatic provisioning](https://developers.cloudflare.com/workers/wrangler/configuration/#automatic-provisioning) · [Wrangler commands](https://developers.cloudflare.com/workers/wrangler/commands/) · [Cloudflare IaC overview](https://developers.cloudflare.com/workers/platform/infrastructure-as-code/)

### Authentication

- **Local:** `alchemy profile edit --add Cloudflare` supports browser OAuth or a scoped API token; credentials are stored in an Alchemy profile under `~/.alchemy`. No `wrangler login` is required for Alchemy. [Alchemy Cloudflare setup](https://alchemy.run/cloudflare/setup) · [Profiles](https://alchemy.run/environments/profiles)
- **CI:** Cloudflare auth comes from `CLOUDFLARE_ACCOUNT_ID` plus `CLOUDFLARE_API_TOKEN` (or API key + email). GitHub Actions examples run `alchemy deploy --stage ... --yes`. Scope the token to the exact products the stack manages. [CI credentials](https://alchemy.run/environments/ci/#cloudflare) · [Cloudflare IaC auth prerequisites](https://developers.cloudflare.com/workers/platform/infrastructure-as-code/)
- **State store:** using `Cloudflare.state()` needs permissions for its Worker/DO/Secrets Store bootstrap and use, beyond permissions to upload the app Worker. Check the CI guide's state-store note before minting the production token. [Alchemy CI Cloudflare permissions](https://alchemy.run/environments/ci/#cloudflare) · [State-store bootstrap](https://alchemy.run/state-store/#first-run-bootstrap)
- **Wrangler:** Cloudflare's IaC docs likewise require Account ID and API token (not the Global API Key) for direct API deployment examples; the current repo passes `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` through the Wrangler Action. [Cloudflare Workers IaC docs](https://developers.cloudflare.com/workers/platform/infrastructure-as-code/) · [Repo deploy workflow](../../.github/workflows/deploy-master.yml)

## Repository integration and boundaries

### Monorepo / SvelteKit

**Yes, structurally.** Alchemy documents both one root Stack and multiple stacks under package directories for monorepos, and documents pnpm in its CI setup. A practical layout here would be `apps/web/alchemy.run.ts` or a root deployment entrypoint that builds/deploys the web app while retaining Phoenix's existing independent workflow. [Monorepo guide](https://alchemy.run/project-structure/monorepo/) · [Multiple stacks](https://alchemy.run/project-structure/monorepo-multi-stack/) · [CI package manager examples](https://alchemy.run/environments/ci/)

The SvelteKit integration is a first-party fit at the framework level: `Cloudflare.Website.SvelteKit` invokes the SvelteKit Vite build and deploys assets/server output as a Worker. However, it injects Alchemy's Cloudflare adapter, replacing a declared adapter, and its official guide says no Wrangler file is needed. Expect to translate current `wrangler.jsonc` Worker settings/bindings into stack props and validate Vite plugins, Sentry sourcemap upload, environment variables/secrets, assets, Hyperdrive and R2 end to end. This is feasible, not automatically compatible. [Alchemy SvelteKit guide](https://alchemy.run/cloudflare/frontend/sveltekit) · [Current `wrangler.jsonc`](../../apps/web/wrangler.jsonc) · [Current web deploy](../../.github/workflows/deploy-master.yml)

### Git-to-production

**Yes as an IaC deploy pipeline; no, not automatic source hosting.** Alchemy's CI guide supplies GitHub Actions examples for production deploys and PR stages/previews, but the repository still owns build triggers, credentials, approvals/concurrency, tests, and secrets. It would mean changing `.github/workflows/deploy-master.yml` from the Wrangler Action to the relevant Alchemy command (and adding appropriate path filters/build env). PR stages are useful for ephemeral Workers, but production zones, names, and stateful/data-bearing resources need explicit stage/removal policies to avoid creating or destroying the wrong environment. [Alchemy CI / PR stages](https://alchemy.run/environments/ci/) · [Stages](https://alchemy.run/environments/stages)

### Phoenix on Fly.io

Alchemy has a real Fly provider and supports merging providers in a single Stack. Its `Fly.Machine` can deploy an existing container image. Its documented `Fly.Service`, however, bundles an Effect/TypeScript entrypoint into a default Node image, which is not this repo's Phoenix release. [Provider composition](https://alchemy.run/infrastructure-as-code/provider/#multiple-providers) · [Fly overview](https://alchemy.run/fly) · [Fly Machine vs Service](https://alchemy.run/providers/fly/reference/machine)

This repository's `fly.toml` builds `apps/phoenix/Dockerfile` and executes `Dhc.Release.migrate()` as a Fly release command; its Fly deploy workflow uses `fly deploy`. The README also describes CI's `FLY_API_TOKEN` and deployment contract. Alchemy's generic Fly image/Machine support does not, by itself, prove parity with that `fly.toml` build + release-command behavior. To manage Phoenix with Alchemy, likely options are: keep `fly deploy` for the Phoenix application while Alchemy manages CF and possibly separately managed Fly resources; or build/publish the Elixir image yourself and model its Fly Machine/app explicitly, while separately running migrations/release steps with careful ordering. Do not move the production Phoenix app until those semantics are demonstrated. [Repo `fly.toml`](../../fly.toml) · [Phoenix deployment README](../../apps/phoenix/README.md) · [Fly deploy workflow](../../.github/workflows/deploy-phoenix-fly.yml)

## Gaps and risks

1. **Beta churn:** current product/docs are on Alchemy 2.0 beta (beta.83 as of research date); release notes include breaking CLI/API changes. Pin Alchemy and check upgrade notes before every bump.
2. **Adoption is not an inert import:** after ownership is transferred, reconciliation can change deployed Worker code/bindings or other resource settings. Start with a detailed plan, exact physical names, and a reversible/non-prod test.
3. **Provider-specific discovery:** `read` is optional and resource-specific. Confirm the exact provider reads/adopts every pre-existing R2/KV/Queue/Email/Hyperdrive object needed before relying on a no-create takeover. Adoption capability is not implied by the existence of a typed resource API.
4. **State and identity:** stack name/stage/logical ID changes alter state identity; accidental stage/name divergence risks collisions or duplicate resources. Team deploys need shared remote state and same-stage deploy serialization/concurrency.
5. **Production resource lifecycle:** resources omitted from a stack can be planned for deletion; stateful buckets/DBs/zones need retention policy and careful destroy semantics. R2 objects in particular make deletion constraints/data-loss impact material.
6. **Two control planes:** Alchemy and Wrangler both configure/deploy Workers. One must be the owner for each Worker/binding/resource. Avoid concurrent deploy jobs or config sources that fight over bindings, assets, routes, secrets, compatibility flags, or deployments.
7. **SvelteKit changes:** Alchemy has an official adapter/build path, but it replaces adapters and may affect current Vite/Sentry/env workflows; prove production parity in a test stage first.
8. **Durable Object rollout compatibility:** beta.82+ deploys DOs using Cloudflare's declarative `exports`; beta.83 calls this a one-way change and requires Alchemy beta.82+ everywhere that deploys the stack, with the first upgraded deploy at 100% traffic. The release says adoption of Wrangler-deployed DO Workers requires Wrangler 4.107+. If this repo later adds DOs, coordinate CLI/CI upgrades and staged deployment before rollout. [beta.83 DO rollout warning](https://alchemy.run/blog/2026-10-12-beta-83/#durable-objects-deploy-with-exports)
9. **Phoenix release semantics:** Fly resource API coverage is not equivalent to preserving Phoenix image build, release command, Ecto migration, secrets, and healthcheck flow. Keep `fly deploy` unless explicitly tested with a custom image/Machine flow.
10. **Cloudflare state-store privilege:** remote state bootstrapping stores its own auth/encryption material and requires a broader permission surface than deploying a Worker alone. Review that extra account footprint/security model.

## Recommendation

**Pilot Alchemy for the Cloudflare half, not as a wholesale replacement for both deploy systems.** First reproduce the existing Cloudflare Worker + static assets + Hyperdrive + R2 config in an isolated/test stage using the official SvelteKit integration, then verify preview, deployment, secrets, sourcemaps, bindings, rollback, state recovery, drift reporting, and adoption plan output. If successful, designate Alchemy as the sole owner of that Worker and those CF resources, migrate the Cloudflare CI step deliberately, and leave the Phoenix `fly deploy` / release command untouched. For any currently existing production CF resource, use a resource-by-resource adoption checklist; do not run a broad production `--adopt` until provider lookups and detailed plan changes are confirmed.

## Primary documentation index

- [Alchemy: What is Alchemy?](https://alchemy.run/what-is-alchemy/)
- [Alchemy: Cloudflare overview and provider reference list](https://alchemy.run/cloudflare)
- [Alchemy: Provider lifecycle/adoption contract](https://alchemy.run/infrastructure-as-code/provider/)
- [Alchemy: Existing resource adoption workflow](https://alchemy.run/cli/adopting-resources/)
- [Alchemy: State stores](https://alchemy.run/state-store/)
- [Alchemy: Drift command](https://alchemy.run/cli/drift/)
- [Alchemy: Cloudflare SvelteKit](https://alchemy.run/cloudflare/frontend/sveltekit)
- [Cloudflare: Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/)
- [Cloudflare: Workers IaC options](https://developers.cloudflare.com/workers/platform/infrastructure-as-code/)
- [Cloudflare: Terraform provider](https://developers.cloudflare.com/terraform/)
