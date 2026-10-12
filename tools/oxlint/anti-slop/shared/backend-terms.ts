/**
 * Beginners' Workshop domain terms that must never reach staff- or
 * person-facing copy (ALE-420), each with the copy word to use instead.
 * Shared by the `anti-slop/no-backend-terms-in-copy` rule (strings in
 * `<script>`) and the web unit test that scans Svelte markup.
 *
 * Matching is case-insensitive and whole-phrase; plurals and verb forms are
 * included. Order matters: a longer phrase precedes the word it contains.
 */
export type BackendTerm = {
  readonly term: string;
  readonly copy: string;
  readonly pattern: RegExp;
};

export const BACKEND_TERMS: readonly BackendTerm[] = [
  { term: "Intake", copy: "workshop place", pattern: /\bintakes?\b/i },
  { term: "Batch", copy: "offer round", pattern: /\bbatch(?:es)?\b/i },
  { term: "Carried Fee", copy: "workshop credit", pattern: /\bcarried[\s-]+fees?\b/i },
  { term: "Payment Cutoff", copy: "payment deadline", pattern: /\bpayment[\s-]+cut-?offs?\b/i },
  { term: "Finalisation", copy: "attendance confirmed", pattern: /\bfinali[sz]ations?\b/i },
  {
    term: "Seat Hold",
    copy: "place (reserved during checkout)",
    pattern: /\bseat[\s-]+holds?\b/i,
  },
  { term: "seat", copy: "place", pattern: /\bseats?\b/i },
  {
    term: "Fast-track",
    copy: "add to this workshop",
    pattern: /\bfast[\s-]?track(?:s|ed|ing)?\b/i,
  },
  { term: "Waitlist entry", copy: "person", pattern: /\bwaitlist[\s-]+entr(?:y|ies)\b/i },
  { term: "contact-from", copy: "offers start", pattern: /\bcontact[\s-]+from\b/i },
  { term: "Console", copy: "Manage", pattern: /\bconsoles?\b/i },
];

/**
 * A string with no whitespace and no capital letter is a machine token, not
 * copy: a snake_case enum value, a kebab-case id, a path or a URL.
 */
export function isMachineToken(text: string): boolean {
  return !/[\sA-Z]/.test(text);
}

/** The first backend term the copy shows, if any. */
export function findBackendTerm(copy: string): BackendTerm | undefined {
  return BACKEND_TERMS.find(({ pattern }) => pattern.test(copy));
}
