import * as v from 'valibot';
import { SocialMediaConsent } from '$lib/types';
import { dobValidator, phoneNumberValidator } from './commonValidators';

const formValidation = v.object({
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	email: v.pipe(
		v.string(),
		v.nonEmpty('Please enter your email.'),
		v.email('Email is invalid.'),
		v.transform((input) => input.toLowerCase())
	),
	phoneNumber: phoneNumberValidator(),
	dateOfBirth: dobValidator,
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
