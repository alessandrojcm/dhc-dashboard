/**
 * Template sync pipeline (ADR 0022 — Code-Authored Templates Synced to
 * Resend-Hosted Templates; ALE-260).
 *
 * Modes:
 *   tsx scripts/sync.tsx            upsert every template as a Resend draft
 *   tsx scripts/sync.tsx --publish  upsert, then publish each template
 *   tsx scripts/sync.tsx --smoke    fail unless every whitelisted Email Kind
 *                                   resolves to a published Resend template
 *
 * Pull requests run the default mode (drafts only); merging to main runs
 * `--publish` followed by `--smoke`, so publishing always gates on review
 * plus required checks. Reruns are idempotent: templates are addressed by
 * their kebab-case alias and updated in place.
 *
 * The pure helpers ({@link placeholderProps}, {@link absolutizeAssets},
 * {@link findUnpublished}) are exported for the vitest suite; everything else
 * only runs when the script is invoked directly.
 */

import { pathToFileURL } from "node:url";

import type { ReactElement } from "react";
import type { CreateTemplateOptions, ErrorResponse, Template, UpdateTemplateOptions } from "resend";
import { Resend } from "resend";
import { render } from "react-email";

import InviteMemberEmail from "../emails/invite-member";
import MagicLinkEmail from "../emails/magic-link";
import WorkshopAnnouncementEmail from "../emails/workshop-announcement";
import WorkshopRegistrationEmail from "../emails/workshop-registration";
import WorkshopRegistrationErrorEmail from "../emails/workshop-registration-error";

import {
  EMAIL_KINDS,
  listTemplates,
  templateAlias,
  type EmailKind,
  type TemplateMetadata,
} from "../src/index";

/**
 * Cloudflare-hosted origin for template assets: an R2 bucket fronted by a
 * custom domain (`mise run email-asset-upload` fills it). Serving the crest
 * through the app's Worker would couple every email open to web deploys.
 */
const DEFAULT_ASSETS_BASE_URL = "https://assets.dublinhemaclub.com";

/**
 * Props bound to literal `{{{KEY}}}` placeholders so the uploaded HTML keeps
 * Resend's server-side interpolation markers instead of sample data.
 */
type PlaceholderProps = Record<string, string>;

/**
 * Maps every declared variable to its literal triple-brace placeholder.
 * React renders braces verbatim (it only escapes `<`, `&` and quotes), so
 * the tokens survive into the uploaded HTML exactly as Resend expects them.
 */
export function placeholderProps(template: TemplateMetadata): PlaceholderProps {
  return Object.fromEntries(template.variables.map((v) => [v.key, `{{{${v.key}}}}`]));
}

/**
 * Rewrites the layout's preview-only relative asset sources (`/static/…`)
 * to absolute URLs on the club site — relative image sources break in email
 * clients. Fulfils the contract documented on `LOGO_SRC` in
 * `emails/_components/layout.tsx`.
 */
export function absolutizeAssets(html: string, baseUrl: string): string {
  return html.replaceAll('src="/static/', `src="${baseUrl}/`);
}

/** The subset of a listed Resend template the checks care about. */
export interface RemoteTemplateStatus {
  alias: string | null;
  status: Template["status"];
}

/** A template listed from Resend, narrowed to what the sync needs. */
export type RemoteTemplate = Pick<Template, "id"> & RemoteTemplateStatus;

/**
 * Returns every whitelisted kind whose alias is missing from Resend or whose
 * latest published version does not exist — the guard against a typo'd alias
 * or an unpublished edit surfacing only at send time.
 */
export function findUnpublished(
  kinds: readonly EmailKind[],
  remote: readonly RemoteTemplateStatus[],
): EmailKind[] {
  const byAlias = new Map(remote.map((t) => [t.alias, t.status]));

  return kinds.filter((kind) => {
    const status = byAlias.get(templateAlias(kind));
    return status === undefined || status !== "published";
  });
}

/**
 * Per-kind renderers passing exactly the variables each component actually
 * interpolates. Variables declared for caller parity but never rendered in
 * markup are deliberately omitted — Resend needs them declared on the
 * template (which `payloadFor` does), not present in the HTML.
 */
const RENDERERS = {
  inviteMember: (p: PlaceholderProps): ReactElement => (
    <InviteMemberEmail INVITATION_LINK={p.INVITATION_LINK ?? ""} />
  ),
  magicLink: (p: PlaceholderProps): ReactElement => (
    <MagicLinkEmail LOGIN_LINK={p.LOGIN_LINK ?? ""} />
  ),
  workshopAnnouncement: (p: PlaceholderProps): ReactElement => (
    <WorkshopAnnouncementEmail MESSAGE={p.MESSAGE ?? ""} MEMBER_FIRST_NAME={p.MEMBER_FIRST_NAME} />
  ),
  workshopRegistration: (p: PlaceholderProps): ReactElement => (
    <WorkshopRegistrationEmail WORKSHOP_NAME={p.WORKSHOP_NAME ?? ""} />
  ),
  workshopRegistrationError: (p: PlaceholderProps): ReactElement => (
    <WorkshopRegistrationErrorEmail WORKSHOP_NAME={p.WORKSHOP_NAME ?? ""} />
  ),
} satisfies Record<EmailKind, (props: PlaceholderProps) => ReactElement>;

export async function renderTemplateHtml(kind: EmailKind, assetsBaseUrl: string): Promise<string> {
  const metadata = listTemplates().find((t) => t.kind === kind);
  if (!metadata) throw new Error(`No template metadata registered for kind "${kind}"`);

  const html = await render(RENDERERS[kind](placeholderProps(metadata)));
  return absolutizeAssets(html, assetsBaseUrl);
}

/** Resend's per-variable payload shape (identical for create and update). */
type ResendTemplateVariable = NonNullable<UpdateTemplateOptions["variables"]>[number];

function payloadFor(metadata: TemplateMetadata, html: string): CreateTemplateOptions {
  return {
    name: metadata.kind,
    alias: metadata.alias,
    subject: metadata.subject,
    from: metadata.from,
    html,
    variables: metadata.variables.map((v): ResendTemplateVariable => {
      if (v.type === "number") {
        return v.fallback === undefined
          ? { key: v.key, type: "number" }
          : { key: v.key, type: "number", fallbackValue: v.fallback };
      }
      return v.fallback === undefined
        ? { key: v.key, type: "string" }
        : { key: v.key, type: "string", fallbackValue: v.fallback };
    }),
  };
}

function unwrap<T>(result: { data: T | null; error: ErrorResponse | null }, what: string): T {
  if (result.error) {
    throw new Error(
      `${what} failed: ${result.error.name}${result.error.statusCode ? ` (${result.error.statusCode})` : ""}: ${result.error.message}`,
    );
  }
  if (result.data === null) throw new Error(`${what} failed: empty response`);
  return result.data;
}

async function listAllTemplates(resend: Resend): Promise<RemoteTemplate[]> {
  const items: RemoteTemplate[] = [];
  let after: string | undefined;

  do {
    const page = unwrap(await resend.templates.list({ limit: 100, after }), "Listing templates");
    items.push(...page.data);
    after = page.has_more ? page.data.at(-1)?.id : undefined;
  } while (after);

  return items;
}

async function main(): Promise<number> {
  const flags = process.argv.slice(2);
  const publish = flags.includes("--publish");
  const smoke = flags.includes("--smoke");
  const unknown = flags.filter((f) => f !== "--publish" && f !== "--smoke");
  if (unknown.length > 0) {
    console.error(`Unknown flag(s): ${unknown.join(", ")}. Supported: --publish, --smoke`);
    return 2;
  }

  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) {
    console.error(
      "RESEND_API_KEY is not set. Use the Full Access key (CI secret RESEND_API_KEY_CI); send-only keys cannot manage templates.",
    );
    return 1;
  }
  const resend = new Resend(apiKey);
  const assetsBaseUrl = process.env.EMAIL_ASSETS_BASE_URL ?? DEFAULT_ASSETS_BASE_URL;

  if (smoke) return runSmoke(resend);

  const remoteByAlias = new Map((await listAllTemplates(resend)).map((t) => [t.alias, t]));
  let failed = false;

  for (const metadata of listTemplates()) {
    try {
      const html = await renderTemplateHtml(metadata.kind, assetsBaseUrl);
      const payload = payloadFor(metadata, html);
      const existing = remoteByAlias.get(metadata.alias);

      const { id } = existing
        ? unwrap(await resend.templates.update(existing.id, payload), `Update ${metadata.alias}`)
        : unwrap(await resend.templates.create(payload), `Create ${metadata.alias}`);

      if (publish) {
        unwrap(await resend.templates.publish(id), `Publish ${metadata.alias}`);
        console.log(`✓ ${metadata.alias} published`);
      } else {
        console.log(`✓ ${metadata.alias} ${existing ? "updated (draft)" : "created (draft)"}`);
      }
    } catch (error) {
      failed = true;
      console.error(
        `✗ ${metadata.alias}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  if (publish && !failed) {
    console.log("Smoke-checking published templates…");
    return runSmoke(resend);
  }
  if (failed) console.error("Sync finished with failures");
  return failed ? 1 : 0;
}

/** Fails unless every whitelisted Email Kind resolves to a published template. */
async function runSmoke(resend: Resend): Promise<number> {
  const unpublished = findUnpublished(EMAIL_KINDS, await listAllTemplates(resend));
  for (const kind of unpublished) {
    console.error(`✗ ${kind}: no published template for alias "${templateAlias(kind)}"`);
  }
  if (unpublished.length > 0) return 1;
  console.log(`✓ all ${EMAIL_KINDS.length} whitelisted kinds resolve to published templates`);
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main();
}
