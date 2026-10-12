/**
 * Beginners' Workshop domain terms that must never reach staff- or
 * person-facing copy (ALE-420), each with the copy word to use instead.
 * The list lives in `backend-terms.json`, which Phoenix's
 * `beginners_workshop_copy_test.exs` reads too. Shared by the
 * `anti-slop/no-backend-terms-in-copy` rule (strings in `<script>`) and the
 * web unit test that scans Svelte markup.
 */
import list from "./backend-terms.json" with { type: "json" };

export type BackendTerm = {
  readonly term: string;
  readonly copy: string;
  readonly pattern: RegExp;
};

export const BACKEND_TERMS: readonly BackendTerm[] = list.terms.map(({ term, copy, pattern }) => ({
  term,
  copy,
  pattern: new RegExp(pattern, "i"),
}));

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
