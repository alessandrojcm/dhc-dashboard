import * as v from "valibot";

export const ProcessRefundSchema = v.object({
	registration_id: v.pipe(v.string(), v.uuid("Must be a valid UUID")),
	reason: v.pipe(
		v.string(),
		v.minLength(1, "Reason is required"),
		v.maxLength(500, "Reason must be less than 500 characters"),
	),
});

export type ProcessRefundInput = v.InferInput<typeof ProcessRefundSchema>;
