/**
 * Template metadata schema for the code-authored transactional email
 * templates (ADR 0022 — Code-Authored Templates Synced to Resend-Hosted
 * Templates).
 *
 * Each component file in `emails/` exports its metadata via
 * {@link defineTemplate}, making TypeScript the single schema authority for
 * what each Email Kind requires: default subject, default sender, and the
 * declared typed variables. The Elixir side keeps only its generic
 * string|number validation and Resend enforces the per-template variable
 * contract at send time.
 *
 * Constraints encoded here mirror Resend's template rules:
 *
 * - variable keys are UPPER_SNAKE and referenced as {{{KEY}}} in markup;
 * - at most 20 declared variables per template;
 * - reserved names cannot be declared.
 *
 * The fallback/type correlation is expressed statically through the
 * {@link TemplateVariable} discriminated union, so an invalid pairing fails
 * compilation instead of validation.
 */

/** The five whitelisted Email Kinds — mirrors `@transactional_ids` in `Dhc.Email.Worker`. */
export const EMAIL_KINDS = [
  "inviteMember",
  "workshopAnnouncement",
  "workshopRegistration",
  "workshopRegistrationError",
  "magicLink",
] as const;

export type EmailKind = (typeof EMAIL_KINDS)[number];

interface VariableBase {
  /** UPPER_SNAKE key as declared on the Resend-hosted template (`{{{KEY}}}`). */
  readonly key: string;
}

export interface StringTemplateVariable extends VariableBase {
  readonly type: "string";
  /** Optional fallback rendered when a send omits the variable. */
  readonly fallback?: string;
}

export interface NumberTemplateVariable extends VariableBase {
  readonly type: "number";
  readonly fallback?: number;
}

export type TemplateVariable = StringTemplateVariable | NumberTemplateVariable;

export type TemplateVariableType = TemplateVariable["type"];

export interface TemplateMetadata {
  /** The stable provider-neutral Email Kind (`inviteMember`, …). */
  readonly kind: EmailKind;
  /** Kebab-case alias derived from the kind; Resend templates are addressed by it. */
  readonly alias: string;
  readonly subject: string;
  /** Default sender in `Name <addr>` form. */
  readonly from: string;
  readonly variables: readonly TemplateVariable[];
}

export interface TemplateDefinition {
  kind: EmailKind;
  subject: string;
  from: string;
  variables: readonly TemplateVariable[];
}

/** Names Resend reserves on every template; declaring them is an error. */
export const RESERVED_VARIABLE_NAMES = new Set([
  "FIRST_NAME",
  "LAST_NAME",
  "EMAIL",
  "RESEND_UNSUBSCRIBE_URL",
  "contact",
  "this",
]);

/** Resend allows at most 20 declared variables per template. */
const MAX_VARIABLES = 20;

const UPPER_SNAKE = /^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*$/;
const SENDER_WITH_ADDRESS = /<[^<>]+@[^<>]+\.[^<>]+>|^[^\s<]+@[^\s<]+\.[^\s<]+$/;

/**
 * Derives the kebab-case template alias of an Email Kind. Sends address the
 * Resend-hosted template by this alias, so no kind→ID configuration map ever
 * exists at runtime (ADR 0022).
 */
export function templateAlias(kind: string): string {
  return kind.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();
}

function validate(definition: TemplateDefinition): void {
  const { kind, subject, from, variables } = definition;

  if (subject.trim() === "") {
    throw new Error(`Template "${kind}" must declare a non-empty subject`);
  }

  if (!SENDER_WITH_ADDRESS.test(from)) {
    throw new Error(`Template "${kind}" must declare a "from" sender ("Name <addr>" or "addr")`);
  }

  if (variables.length > MAX_VARIABLES) {
    throw new Error(
      `Template "${kind}" declares ${variables.length} variables; Resend allows at most ${MAX_VARIABLES}`,
    );
  }

  const seen = new Set<string>();

  for (const { key } of variables) {
    if (!UPPER_SNAKE.test(key)) {
      throw new Error(
        `Template "${kind}" variable "${key}" must be UPPER_SNAKE (e.g. INVITATION_LINK)`,
      );
    }

    if (RESERVED_VARIABLE_NAMES.has(key.toUpperCase())) {
      throw new Error(`Template "${kind}" variable "${key}" is reserved by Resend`);
    }

    if (seen.has(key)) {
      throw new Error(`Template "${kind}" declares duplicate variable "${key}"`);
    }
    seen.add(key);
  }
}

/**
 * Declares a template's metadata, validating Resend's constraints eagerly so
 * a bad definition fails at import time instead of at send or sync time.
 */
export function defineTemplate(definition: TemplateDefinition): TemplateMetadata {
  validate(definition);

  return Object.freeze({
    kind: definition.kind,
    alias: templateAlias(definition.kind),
    subject: definition.subject,
    from: definition.from,
    variables: Object.freeze([...definition.variables].map((v) => Object.freeze(v))),
  });
}
