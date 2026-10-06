import * as v from "valibot";
import type { MemberUpdateRequest } from "@dhc/api-client";
import {
	dateOfBirth,
	gender,
	phoneNumber,
	pronouns,
	requiredText,
} from "#lib/schemas/fields.js";
import { SocialMediaConsent } from "#lib/types.js";

const entries = {
	firstName: requiredText("First name is required."),
	lastName: requiredText("Last name is required."),
	phoneNumber: phoneNumber(),
	dateOfBirth: dateOfBirth(),
	pronouns: pronouns(),
	gender: gender(),
	medicalConditions: v.optional(v.string(), ""),
	nextOfKin: requiredText("Please enter your next of kin."),
	nextOfKinNumber: phoneNumber("Phone number of your next of kin is required."),
	weapon: v.pipe(
		v.optional(v.array(v.string("Please select your preferred weapon.")), []),
		v.transform((weapons) => weapons.filter((weapon) => weapon !== "")),
		v.minLength(1, "Please select at least one weapon."),
	),
	insuranceFormSubmitted: v.optional(v.boolean()),
	socialMediaConsent: v.optional(
		v.enum(SocialMediaConsent, "Please select an option"),
	),
};

/**
 * The member profile edit form, used for both `form(...)` and
 * `.preflight(...)`. Its input is what the form submits; its output is the
 * `membersUpdate` request body (formatted phone numbers, blank weapon entries
 * dropped, form names mapped to the contract's). The login email belongs to
 * the Authentication Principal, so it is neither accepted nor sent.
 */
const memberProfileSchema = v.pipe(
	v.object(entries),
	v.transform(({ nextOfKin, nextOfKinNumber, weapon, ...rest }) => {
		return {
			...rest,
			nextOfKinName: nextOfKin,
			nextOfKinPhone: nextOfKinNumber,
			preferredWeapon: weapon,
		} satisfies MemberUpdateRequest;
	}),
);

export type MemberProfileInput = v.InferInput<typeof memberProfileSchema>;
export type MemberProfileBody = v.InferOutput<typeof memberProfileSchema>;

export default memberProfileSchema;
