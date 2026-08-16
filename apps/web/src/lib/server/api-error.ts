import * as v from "valibot";

const ApiErrorResponseSchema = v.object({
	errors: v.optional(
		v.object({
			detail: v.optional(v.string()),
		}),
	),
});

export function apiErrorDetail(cause: unknown): string | undefined {
	const result = v.safeParse(ApiErrorResponseSchema, cause);
	return result.success ? result.output.errors?.detail : undefined;
}

export function apiErrorMessage(cause: unknown, fallback: string): string {
	return apiErrorDetail(cause) ?? fallback;
}
