/**
 * Reads Phoenix's problem details for the Training Announcement slices
 * (ALE-330). `TrainingAnnouncementHTTP` answers a rejected write with
 * `{ errors: { detail, code?, fields? } }` — for example an elapsed first send
 * instant on `postTime`, or a schedule shape that sets neither a weekday nor a
 * date on `oneOffDate`.
 *
 * Parsing happens once here so the sheet can attach a message to the field that
 * caused it instead of collapsing everything into one banner, and so the
 * ky-thrown body (`{ data: { errors } }`) needs no type assertion at the call
 * site.
 */
import * as v from "valibot";

const ProblemSchema = v.object({
	errors: v.object({
		detail: v.optional(v.string()),
		code: v.optional(v.string()),
		fields: v.optional(v.record(v.string(), v.array(v.string()))),
	}),
});

const ProblemClientSchema = v.union([
	ProblemSchema,
	v.object({ data: ProblemSchema }),
]);

export type AnnouncementFieldMessages = {
	/** Public camelCase request field, as the API names it. */
	field: string;
	messages: string[];
};

export type AnnouncementProblem = {
	detail?: string;
	code?: string;
	fieldMessages: AnnouncementFieldMessages[];
};

export function announcementProblem(
	cause: unknown,
): AnnouncementProblem | undefined {
	const parsed = v.safeParse(ProblemClientSchema, cause);
	if (!parsed.success) return undefined;
	const errors =
		"data" in parsed.output ? parsed.output.data.errors : parsed.output.errors;
	return {
		detail: errors.detail,
		code: errors.code,
		fieldMessages: Object.entries(errors.fields ?? {}).map(
			([field, messages]) => ({
				field,
				messages,
			}),
		),
	};
}

/** Detail text for an announcement write, with a caller-chosen fallback. */
export function announcementProblemMessage(
	cause: unknown,
	fallback: string,
): string {
	return announcementProblem(cause)?.detail ?? fallback;
}
