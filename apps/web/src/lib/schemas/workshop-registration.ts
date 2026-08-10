import * as v from "valibot";

/**
 * Create external checkout session command input schema.
 */
export const CreateExternalCheckoutSessionCommandSchema = v.object({
	workshopId: v.pipe(v.string(), v.uuid("Invalid workshop ID")),
	paymentAttemptId: v.pipe(v.string(), v.uuid("Invalid payment attempt ID")),
});

export type CreateExternalCheckoutSessionCommandData = v.InferOutput<
	typeof CreateExternalCheckoutSessionCommandSchema
>;
