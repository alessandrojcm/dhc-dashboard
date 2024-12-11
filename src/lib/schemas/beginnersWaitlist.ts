import dayjs from 'dayjs';
import * as v from 'valibot';
import parsePhoneNumber from 'libphonenumber-js';
import { SocialMediaConsent } from '$lib/types';

const formValidation = v.object({
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	email: v.pipe(v.string(), v.nonEmpty('Please enter your email.'), v.email('Email is invalid.')),
	phoneNumber: v.pipe(
		v.string(),
		v.nonEmpty('Phone number is required.'),
		v.check((input) => Boolean(parsePhoneNumber(input)?.isValid), 'Invalid phone number'),
		v.transform((input) => parsePhoneNumber(input)!.formatInternational())
	),
	dateOfBirth: v.pipe(
		v.date('Date of birth is required.'),
		v.check((input) => dayjs().diff(input, 'years') >= 16, 'You must be at least 16 years old.')
	),
	medicalConditions: v.pipe(v.string()),
	pronouns: v.pipe(
		v.string(),
		v.check(
			(input) => /^\/?[\w-]+(\/[\w-]+)*\/?$/.test(input),
			'Pronouns must be written between slashes (e.g., he/him/they).'
		)
	),
	gender: v.string(),
	socialMediaConsent: v.optional(
		v.enum(SocialMediaConsent, 'Please select an option'),
		SocialMediaConsent.no
	)
});

export default formValidation;

export type BeginnersFormSchema = typeof formValidation;
