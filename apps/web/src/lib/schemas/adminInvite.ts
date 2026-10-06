import * as v from "valibot";
import {
	dateOfBirth,
	email,
	phoneNumber,
	requiredText,
} from "#lib/schemas/fields.js";

// Membership discount tier indicated at issue time; Phoenix resolves the
// matching private Stripe coupon at acceptance.
const pricingTierSchema = v.optional(
	v.picklist(["standard", "coach", "student"]),
	"standard",
);

/**
 * One invite as the invite drawer collects it. Its output is an
 * `invitationsCreate` invite entry (lowercased email, formatted phone number,
 * `YYYY-MM-DD` date of birth of someone at least 16). The output parses again
 * unchanged, so entries the drawer validated can be sent to the command.
 */
const adminInviteSchema = v.object({
	firstName: requiredText("First name is required."),
	lastName: requiredText("Last name is required."),
	email: email("Please enter an email."),
	phoneNumber: phoneNumber(),
	dateOfBirth: dateOfBirth(),
	pricingTier: pricingTierSchema,
});

/**
 * The `submitBulkInvites` command input; its output is the `invitationsCreate`
 * request body.
 */
const bulkInviteSchema = v.object({
	invites: v.pipe(
		v.array(adminInviteSchema),
		v.minLength(1, "Add at least one invite."),
	),
});

export { adminInviteSchema, bulkInviteSchema };
export type AdminInviteInput = v.InferInput<typeof adminInviteSchema>;
export type AdminInvite = v.InferOutput<typeof adminInviteSchema>;
export type BulkInviteBody = v.InferOutput<typeof bulkInviteSchema>;
