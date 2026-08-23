import * as v from "valibot";
import { dobValidator, phoneNumberValidator } from "./commonValidators";

// Membership discount tier indicated at issue time; Phoenix resolves the
// matching private Stripe coupon at acceptance.
const pricingTierSchema = v.optional(
	v.picklist(["standard", "coach", "student"]),
	"standard",
);

const adminInviteSchema = v.object({
	firstName: v.pipe(v.string(), v.nonEmpty("First name is required.")),
	lastName: v.pipe(v.string(), v.nonEmpty("Last name is required.")),
	email: v.pipe(
		v.string(),
		v.nonEmpty("Please enter an email."),
		v.email("Email is invalid."),
		v.transform((input) => input.toLowerCase()),
	),
	phoneNumber: phoneNumberValidator(),
	dateOfBirth: dobValidator,
	pricingTier: pricingTierSchema,
});

const adminInviteRemoteSchema = v.object({
	...adminInviteSchema.entries,
	dateOfBirth: v.pipe(v.string(), v.nonEmpty("Date of birth is required.")),
});

const bulkInviteSchema = v.object({
	invites: v.pipe(v.array(adminInviteSchema), v.minLength(1)),
});

const bulkInviteRemoteSchema = v.object({
	invites: v.pipe(v.array(adminInviteRemoteSchema), v.minLength(1)),
});

export {
	adminInviteSchema,
	adminInviteRemoteSchema,
	bulkInviteSchema,
	bulkInviteRemoteSchema,
};
export type BulkInviteSchema = v.InferInput<typeof bulkInviteSchema>;
export type BulkInviteSchemaOutput = v.InferOutput<typeof bulkInviteSchema>;
export type AdminInviteSchema = v.InferInput<typeof adminInviteSchema>;
export type AdminInviteSchemaOutput = v.InferOutput<typeof adminInviteSchema>;
