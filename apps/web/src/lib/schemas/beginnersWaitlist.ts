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

/**
 * Phoenix holds a first name to the Intake Email `firstName` placeholder
 * maximum (the `WaitlistEntryCreateRequest` contract's `maxLength`).
 */
export const FIRST_NAME_MAX_LENGTH = 40;

const entries = {
	firstName: v.pipe(
		requiredText("First name is required."),
		v.maxLength(
			FIRST_NAME_MAX_LENGTH,
			`First name must be at most ${FIRST_NAME_MAX_LENGTH} characters.`,
		),
	),
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
