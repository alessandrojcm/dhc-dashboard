import dayjs from "dayjs";
import * as v from "valibot";
import { SocialMediaConsent } from "$lib/types";
import { dobValidator, phoneNumberValidator } from "./commonValidators";

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

const formValidation = v.pipe(
	v.object({
		firstName: v.pipe(v.string(), v.nonEmpty("First name is required.")),
		lastName: v.pipe(v.string(), v.nonEmpty("Last name is required.")),
		email: v.pipe(
			v.string(),
			v.nonEmpty("Please enter your email."),
			v.email("Email is invalid."),
			v.transform((input) => input.toLowerCase()),
		),
		phoneNumber: phoneNumberValidator(),
		dateOfBirth: dobValidator,
		medicalConditions: v.pipe(v.string()),
		pronouns: v.pipe(
			v.string(),
			v.check(
				(input) => /^\/?[\w-]+(\/[\w-]+)*\/?$/.test(input),
				"Pronouns must be written between slashes (e.g., he/him/they).",
			),
		),
		gender: v.pipe(v.string(), v.nonEmpty("Please select your gender.")),
		socialMediaConsent: v.optional(
			v.enum(SocialMediaConsent, "Please select an option"),
			SocialMediaConsent.no,
		),
		...guardianDataSchema.entries,
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
