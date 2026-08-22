# @dhc/email-templates

Code-authored transactional email templates (ADR 0022). Each Email Kind is a
React Email component in `emails/` whose file also declares its metadata —
default subject, default sender, declared variables — via `defineTemplate`,
making TypeScript the single schema authority for what each Kind requires.

The five whitelisted kinds mirror `@transactional_ids` in `Dhc.Email.Worker`:
`inviteMember`, `workshopAnnouncement`, `workshopRegistration`,
`workshopRegistrationError`, `magicLink`.

## How templates reach Resend

Templates are **hosted at Resend** and addressed at send time by a stable
alias: the kebab-case of the Email Kind (`magicLink` → `magic-link`). The sync
pipeline renders every component to HTML and upserts it by that alias through
the official Resend SDK's Templates API. Rerunning is idempotent.

```bash
pnpm --filter @dhc/email-templates sync            # upsert drafts (what CI runs on PRs)
pnpm --filter @dhc/email-templates sync:publish    # upsert + publish   (what CI runs on main)
pnpm --filter @dhc/email-templates smoke           # fail unless every kind has a published template
```

Both write modes require a **Full Access** API key in `RESEND_API_KEY`
(CI secret `RESEND_API_KEY_CI`); send-only keys cannot manage templates.

### Asset hosting (Cloudflare R2)

Rendered HTML must reference the club crest by absolute URL — relative image
sources break in email clients. Assets live in a dedicated Cloudflare R2
bucket (`dhc-email-assets`) fronted by `https://assets.dublinhemaclub.com`,
kept fully decoupled from the web app's Worker. The sync rewrites every
preview-relative `/static/…` source onto that origin
(`EMAIL_ASSETS_BASE_URL` overrides it).

One-time bootstrap, then only when assets under `emails/static/` change:

```bash
wrangler r2 bucket create dhc-email-assets     # plus attach the assets.dublinhemaclub.com custom domain in the CF dashboard
mise run email-asset-upload                    # wrangler r2 object put <bucket>/logo.png …; needs CLOUDFLARE_API_TOKEN or wrangler login
```

Rendered HTML keeps literal `{{{VARIABLE}}}` markers — the render props are
placeholders, never sample data — so Resend substitutes real values at send
time. Variables are declared on the template even when the markup does not
render them.

## CI wiring

`.github/workflows/email-templates.yml` gates like every other pipeline: a
change-detection job (`dorny/paths-filter`) skips everything unless
`packages/email-templates/**` (or workspace lockfiles / the workflow itself)
changed; lint, typecheck and tests run first.

- **Pull requests upload drafts only.** Nothing on Resend changes publicly
  until merge.
- **Merging to main publishes**, then smoke-checks that all five aliases
  resolve to published templates. Publishing therefore gates on review plus
  required checks — never an arbitrary push.

Make **Email Templates / Sync templates to Resend** a required status check so
unreviewed template changes cannot reach `main`.

## Drift policy

**The repository is the source of truth for template content; the next sync
overwrites any dashboard edit.** Editing a template in Resend's dashboard is
drift: it survives only until someone touches the corresponding component and
syncs again. There is no import-back flow.

Recovery for bad publishes is **Resend's version history**: every publish is a
new version, so roll back from the dashboard rather than editing content
there. If you do hot-fix in the dashboard during an incident, port the change
into the component in the same PR that follows the incident — otherwise the
next sync silently reverts it.

## Local preview

```bash
pnpm --filter @dhc/email-templates dev   # React Email preview server on :3000
```

The preview server serves `emails/static/` for relative assets; production
renders get their assets rewritten to the R2 assets origin by the sync
(relative image sources break in email clients).
