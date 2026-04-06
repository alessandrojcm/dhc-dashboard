import * as v from "valibot";

export const registrationSchema = v.object({
	firstName: v.pipe(v.string(), v.minLength(1, "First name is required")),
	lastName: v.pipe(v.string(), v.minLength(1, "Last name is required")),
	email: v.pipe(v.string(), v.email("Valid email is required")),
	phoneNumber: v.optional(v.string()),
	paymentMethodId: v.optional(v.string()),
});

export type RegistrationData = v.InferInput<typeof registrationSchema>;

// ============================================================================
// External Registration Schemas (for public routes)
// ============================================================================

/**
 * External user data for public registration
 */
export const ExternalUserSchema = v.object({
	firstName: v.pipe(v.string(), v.minLength(1, "First name is required")),
	lastName: v.pipe(v.string(), v.minLength(1, "Last name is required")),
	email: v.pipe(v.string(), v.email("Valid email is required")),
	phoneNumber: v.optional(v.nullable(v.string())),
});

export type ExternalUserData = v.InferOutput<typeof ExternalUserSchema>;

/**
 * Create external payment intent input schema
 */
export const CreateExternalPaymentIntentSchema = v.object({
	workshopId: v.pipe(v.string(), v.uuid("Invalid workshop ID")),
	externalUser: ExternalUserSchema,
	currency: v.optional(v.string()),
});

export type CreateExternalPaymentIntentData = v.InferOutput<
	typeof CreateExternalPaymentIntentSchema
>;

/**
 * Complete external registration input schema
 */
export const CompleteExternalRegistrationSchema = v.object({
	workshopId: v.pipe(v.string(), v.uuid("Invalid workshop ID")),
	paymentIntentId: v.pipe(
		v.string(),
		v.minLength(1, "Payment intent ID is required"),
	),
	externalUser: ExternalUserSchema,
});

export type CompleteExternalRegistrationData = v.InferOutput<
	typeof CompleteExternalRegistrationSchema
>;
