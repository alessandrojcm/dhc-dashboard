import * as v from "valibot";
import {
	calculateAge,
	dateOfBirth,
	email,
	gender,
	guardianEntries,
	guardianRules,
	isMinor,
	phoneNumber,
	pronouns,
	requiredText,
} from "#lib/schemas/fields.js";
import { SocialMediaConsent } from "#lib/types.js";

const entries = {
	firstName: requiredText("First name is required."),
	lastName: requiredText("Last name is required."),
	email: email(),
	phoneNumber: phoneNumber(),
	dateOfBirth: dateOfBirth(),
	medicalConditions: v.string(),
	pronouns: pronouns(),
	gender: gender(),
	socialMediaConsent: v.optional(
		v.enum(SocialMediaConsent, "Please select an option"),
		SocialMediaConsent.no,
	),
	...guardianEntries,
};

/**
 * The public Waitlist form, used for both `form(...)` and `.preflight(...)`.
 * Its input is what the form submits; its output is the `waitlistCreateEntry`
 * request body (lowercased email, formatted phone numbers, guardian fields
 * required for minors and stripped for adults).
 */
const beginnersWaitlistSchema = v.pipe(
	v.object(entries),
	...guardianRules<v.InferOutput<v.ObjectSchema<typeof entries, undefined>>>(),
);

export type BeginnersWaitlistInput = v.InferInput<
	typeof beginnersWaitlistSchema
>;
export type BeginnersWaitlistBody = v.InferOutput<
	typeof beginnersWaitlistSchema
>;

export default beginnersWaitlistSchema;

export { isMinor, calculateAge };
