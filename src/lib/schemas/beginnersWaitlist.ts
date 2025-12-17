<<<<<<< HEAD
import dayjs from "dayjs";
import { parsePhoneNumber } from "libphonenumber-js/min";
import * as v from "valibot";
import { SocialMediaConsent } from "$lib/types";
import { dobValidator, phoneNumberValidator } from "./commonValidators";
=======
import dayjs from 'dayjs';
import { parsePhoneNumber } from 'libphonenumber-js/min';
import * as v from 'valibot';
import { SocialMediaConsent } from '$lib/types';
import { dobValidator, phoneNumberValidator } from './commonValidators';
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)

const calculateAge = (dateOfBirth: Date) => dayjs().diff(dateOfBirth, "years");
const isMinor = (dateOfBirth: Date) => calculateAge(dateOfBirth) < 18;

const guardianDataSchema = v.partial(
	v.object({
		guardianFirstName: v.optional(
			v.pipe(v.string(), v.nonEmpty("Guardian first name is required.")),
		),
		guardianLastName: v.optional(
			v.pipe(v.string(), v.nonEmpty("Guardian last name is required.")),
		),
		guardianPhoneNumber: v.optional(
			phoneNumberValidator("Guardian phone number is required."),
		),
	}),
);

/**
 * Simplified schema for client-side type inference and preflight validation.
 * Uses serializable types (string for date, no transforms) to satisfy Standard Schema.
 * Does not include complex cross-field validation or transformations.
 * Use this for Remote Functions form() to get proper TypeScript types.
 */
export const beginnersWaitlistClientSchema = v.object({
<<<<<<< HEAD
	firstName: v.pipe(v.string(), v.nonEmpty("First name is required.")),
	lastName: v.pipe(v.string(), v.nonEmpty("Last name is required.")),
	email: v.pipe(
		v.string(),
		v.nonEmpty("Please enter your email."),
		v.email("Email is invalid."),
	),
	phoneNumber: v.pipe(
		v.string(),
		v.nonEmpty("Phone number is required."),
		v.check((input) => {
			if (input === "") return false;
			try {
				return Boolean(parsePhoneNumber(input ?? "", "IE")?.isValid());
			} catch {
				return false;
			}
		}, "Invalid phone number"),
	),
	dateOfBirth: v.pipe(
		v.string(),
		v.nonEmpty("Date of birth is required."),
		v.check((input) => {
			const date = new Date(input);
			return !isNaN(date.getTime()) && dayjs().diff(date, "years") >= 16;
		}, "You must be at least 16 years old."),
=======
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	email: v.pipe(
		v.string(),
		v.nonEmpty('Please enter your email.'),
		v.email('Email is invalid.')
	),
	phoneNumber: v.pipe(
		v.string(),
		v.nonEmpty('Phone number is required.'),
		v.check((input) => {
			if (input === '') return false;
			try {
				return Boolean(parsePhoneNumber(input ?? '', 'IE')?.isValid());
			} catch {
				return false;
			}
		}, 'Invalid phone number')
	),
	dateOfBirth: v.pipe(
		v.string(),
		v.nonEmpty('Date of birth is required.'),
		v.check((input) => {
			const date = new Date(input);
			return !isNaN(date.getTime()) && dayjs().diff(date, 'years') >= 16;
		}, 'You must be at least 16 years old.')
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
	),
	medicalConditions: v.pipe(v.string()),
	pronouns: v.pipe(
		v.string(),
		v.check(
			(input) => /^\/?[\w-]+(\/[\w-]+)*\/?$/.test(input),
<<<<<<< HEAD
			"Pronouns must be written between slashes (e.g., he/him/they).",
		),
	),
	gender: v.pipe(v.string(), v.nonEmpty("Please select your gender.")),
	socialMediaConsent: v.optional(
		v.enum(SocialMediaConsent, "Please select an option"),
		SocialMediaConsent.no,
	),
	guardianFirstName: v.optional(v.pipe(v.string())),
	guardianLastName: v.optional(v.pipe(v.string())),
	guardianPhoneNumber: v.optional(v.pipe(v.string())),
=======
			'Pronouns must be written between slashes (e.g., he/him/they).'
		)
	),
	gender: v.pipe(v.string(), v.nonEmpty('Please select your gender.')),
	socialMediaConsent: v.optional(
		v.enum(SocialMediaConsent, 'Please select an option'),
		SocialMediaConsent.no
	),
	guardianFirstName: v.optional(v.pipe(v.string())),
	guardianLastName: v.optional(v.pipe(v.string())),
	guardianPhoneNumber: v.optional(v.pipe(v.string()))
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
});

/**
 * Full server-side schema with complex cross-field validation and transformations.
 * Composes the client schema and adds server-specific transformations and cross-field validation.
 * Use this for actual validation on the server.
 */
const formValidation = v.pipe(
	v.object({
		...beginnersWaitlistClientSchema.entries,
		// Override fields that need server-specific transformations
		email: v.pipe(
			v.string(),
			v.nonEmpty("Please enter your email."),
			v.email("Email is invalid."),
			v.transform((input) => input.toLowerCase()),
		),
		phoneNumber: phoneNumberValidator(),
<<<<<<< HEAD
		dateOfBirth: dobValidator,
=======
		dateOfBirth: dobValidator
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
	}),
	v.forward(
		v.partialCheck(
			[["dateOfBirth"], ["guardianFirstName"]],
			({ dateOfBirth, guardianFirstName }) => {
				if (!isMinor(dateOfBirth)) return true;
				return v.safeParse(
					v.required(guardianDataSchema, ["guardianFirstName"]),
					{
						guardianFirstName,
					},
				).success;
			},
			"Guardian first name is required for under 18s.",
		),
		["guardianFirstName"],
	),
	v.forward(
		v.partialCheck(
			[["dateOfBirth"], ["guardianLastName"]],
			({ dateOfBirth, guardianLastName }) => {
				if (!isMinor(dateOfBirth)) return true;
				return v.safeParse(
					v.required(guardianDataSchema, ["guardianLastName"]),
					{
						guardianLastName,
					},
				).success;
			},
			"Guardian last name is required for under 18s.",
		),
		["guardianLastName"],
	),
	v.forward(
		v.partialCheck(
			[["dateOfBirth"], ["guardianPhoneNumber"]],
			({ dateOfBirth, guardianPhoneNumber }) => {
				if (!isMinor(dateOfBirth)) return true;
				return v.safeParse(
					v.required(guardianDataSchema, ["guardianPhoneNumber"]),
					{
						guardianPhoneNumber,
					},
				).success;
			},
			"Guardian phone number is required for under 18s.",
		),
		["guardianPhoneNumber"],
	),
	v.transform((input) => {
		if (!isMinor(input.dateOfBirth)) {
			delete input.guardianFirstName;
			delete input.guardianLastName;
			delete input.guardianPhoneNumber;
			return input;
		}
		return input;
	}),
);

export default formValidation;

export { isMinor, calculateAge };

export type BeginnersFormSchema = v.InferOutput<typeof formValidation>;
