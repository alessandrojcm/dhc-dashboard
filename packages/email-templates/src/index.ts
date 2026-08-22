/**
 * Public surface of `@dhc/email-templates` (ADR 0022 — Code-Authored
 * Templates Synced to Resend-Hosted Templates).
 *
 * The registry maps every whitelisted Email Kind to its template metadata;
 * the sync pipeline iterates it to upload drafts/publishes to Resend, and
 * the send path addresses templates by the derived kebab-case alias. The
 * React components themselves live in `emails/` next to the metadata they
 * declare.
 */

import { magicLinkTemplate } from "../emails/magic-link";
import { inviteMemberTemplate } from "../emails/invite-member";
import { workshopAnnouncementTemplate } from "../emails/workshop-announcement";
import { workshopRegistrationTemplate } from "../emails/workshop-registration";
import { workshopRegistrationErrorTemplate } from "../emails/workshop-registration-error";

import { type EmailKind, type TemplateMetadata, EMAIL_KINDS } from "./template-metadata";

export {
  type EmailKind,
  EMAIL_KINDS,
  type TemplateMetadata,
  type TemplateVariable,
  type TemplateVariableType,
  RESERVED_VARIABLE_NAMES,
  defineTemplate,
  templateAlias,
} from "./template-metadata";

/**
 * Every whitelisted Email Kind must have exactly one template; the key set
 * is the compile-time counterpart of the alias check that asserts each kind
 * has a published Resend template.
 */
export const TEMPLATES: Readonly<Record<EmailKind, TemplateMetadata>> = Object.freeze({
  inviteMember: inviteMemberTemplate,
  workshopAnnouncement: workshopAnnouncementTemplate,
  workshopRegistration: workshopRegistrationTemplate,
  workshopRegistrationError: workshopRegistrationErrorTemplate,
  magicLink: magicLinkTemplate,
});

export function getTemplate(kind: EmailKind): TemplateMetadata {
  return TEMPLATES[kind];
}

export function listTemplates(): readonly TemplateMetadata[] {
  return EMAIL_KINDS.map((kind) => TEMPLATES[kind]);
}
