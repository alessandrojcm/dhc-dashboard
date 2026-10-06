/**
 * Reads the one problem shape Phoenix's `DhcWeb.Problem` renders (ALE-343):
 * `{ errors: { detail, code?, fields? } }`.
 *
 * - `detail` is the human sentence.
 * - `code` is the snake_case domain reason, present only on 409/422 domain
 *   reasons.
 * - `fields` maps public camelCase request field names to messages. Keys may be
 *   dotted (`values.<definitionId>`, `items.<id>`); they stay one field name.
 *
 * The body arrives either plain or wrapped by the ky client as
 * `{ data: body }`; both are accepted, so call sites need no casts.
 */
import * as v from "valibot";

const ProblemSchema = v.object({
	errors: v.object({
		detail: v.fallback(v.optional(v.string()), undefined),
		code: v.fallback(v.optional(v.string()), undefined),
		fields: v.fallback(
			v.optional(v.record(v.string(), v.array(v.string()))),
			undefined,
		),
	}),
});

const ProblemClientSchema = v.union([
	ProblemSchema,
	v.object({ data: ProblemSchema }),
]);

export type ApiFieldMessages = {
	/** Public camelCase request field, as the API names it (may be dotted). */
	field: string;
	messages: string[];
};

export type ApiProblem = {
	detail?: string;
	/** Domain reason; only present on 409/422 domain reasons. */
	code?: string;
	/** Field messages in the order Phoenix sent them; empty when none. */
	fields: ApiFieldMessages[];
};

/** Parses a thrown API error once; `undefined` when it is not a problem body. */
export function apiProblem(cause: unknown): ApiProblem | undefined {
	const parsed = v.safeParse(ProblemClientSchema, cause);
	if (!parsed.success) return undefined;
	const errors =
		"data" in parsed.output ? parsed.output.data.errors : parsed.output.errors;
	return {
		detail: errors.detail,
		code: errors.code,
		fields: Object.entries(errors.fields ?? {}).map(([field, messages]) => ({
			field,
			messages,
		})),
	};
}

export function apiErrorDetail(cause: unknown): string | undefined {
	return apiProblem(cause)?.detail;
}

export function apiErrorMessage(cause: unknown, fallback: string): string {
	return apiErrorDetail(cause) ?? fallback;
}
