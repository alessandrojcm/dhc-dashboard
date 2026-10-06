import dayjs from "dayjs";
import * as v from "valibot";
import { dateOfBirth, phoneNumber } from "#lib/schemas/fields.js";

/**
 * Compatibility exports for the forms not yet on a single schema (member
 * signup/profile and admin invites). New schemas build on
 * `#lib/schemas/fields.js` instead.
 */
export const phoneNumberValidator = phoneNumber;

/**
 * `Date`-typed date of birth for the forms that still convert the field with
 * `new Date(...)`. Applies the same `YYYY-MM-DD` age rule as `fields.ts`.
 */
export const dobValidator = v.pipe(
	v.date("Date of birth is required."),
	v.check(
		(input) => v.is(dateOfBirth(), dayjs(input).format("YYYY-MM-DD")),
		"You must be at least 16 years old.",
	),
);
