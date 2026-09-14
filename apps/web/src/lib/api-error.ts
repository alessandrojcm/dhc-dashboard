import * as v from "valibot";

const ApiErrorResponseSchema = v.object({
	errors: v.optional(
		v.object({
			detail: v.optional(v.string()),
		}),
	),
});

const ApiClientErrorSchema = v.union([
	ApiErrorResponseSchema,
	v.object({ data: ApiErrorResponseSchema }),
]);

export function apiErrorDetail(cause: unknown): string | undefined {
	const result = v.safeParse(ApiClientErrorSchema, cause);
	if (!result.success) return undefined;
	return "data" in result.output
		? result.output.data.errors?.detail
		: result.output.errors?.detail;
}

export function apiErrorMessage(cause: unknown, fallback: string): string {
	return apiErrorDetail(cause) ?? fallback;
}
