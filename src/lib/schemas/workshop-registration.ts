import * as v from "valibot";

export const registrationSchema = v.object({
	firstName: v.pipe(v.string(), v.minLength(1, "First name is required")),
	lastName: v.pipe(v.string(), v.minLength(1, "Last name is required")),
	email: v.pipe(v.string(), v.email("Valid email is required")),
	phoneNumber: v.optional(v.string()),
	paymentMethodId: v.optional(v.string()),
});

export type RegistrationData = v.InferInput<typeof registrationSchema>;
