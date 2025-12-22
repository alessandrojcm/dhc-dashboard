import * as v from 'valibot';
import beginnersWaitlist from './beginnersWaitlist';
import { phoneNumberValidator } from './commonValidators';
import { SocialMediaConsent } from '$lib/types';

export const memberSignupSchema = v.object({
	nextOfKin: v.pipe(v.string(), v.nonEmpty('Please enter your next of kin.')),
	nextOfKinNumber: phoneNumberValidator('Phone number of your next of kin is required.'),
	insuranceFormSubmitted: v.optional(v.boolean()),
	stripeConfirmationToken: v.pipe(
		v.string(),
		v.nonEmpty('Something has gone wrong with your payment, please try again.')
	),
	couponCode: v.optional(v.string())
});

const formSchema = v.object({
	...beginnersWaitlist.entries,
	...v.omit(memberSignupSchema, ['stripeConfirmationToken']).entries,
	weapon: v.pipe(
		v.array(v.string('Please select your preferred weapon.')),
		v.transform((w) => w.filter((v) => v !== '')),
		v.minLength(1, 'Please select at least one weapon.')
	)
});

/**
 * Client-compatible schema for member profile editing.
 * Uses string for dateOfBirth (ISO format) since Remote Functions don't serialize Date objects.
 * Required fields match MemberUpdateSchema from member.service.ts
 */
export const memberProfileClientSchema = v.object({
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	email: v.optional(v.pipe(v.string(), v.email('Email is invalid.'))),
	phoneNumber: v.optional(v.string()),
	dateOfBirth: v.pipe(v.string(), v.nonEmpty('Date of birth is required.')),
	pronouns: v.optional(v.string()),
	gender: v.optional(v.string()),
	medicalConditions: v.optional(v.string()),
	nextOfKin: v.optional(v.string()),
	nextOfKinNumber: v.optional(v.string()),
	weapon: v.optional(v.array(v.string()), []),
	insuranceFormSubmitted: v.optional(v.boolean()),
	socialMediaConsent: v.optional(v.enum(SocialMediaConsent))
});

export type MemberProfileClientInput = v.InferOutput<typeof memberProfileClientSchema>;

export default formSchema;
export type SignupForm = v.InferInput<typeof formSchema>;
export type MemberSignupForm = v.InferInput<typeof memberSignupSchema>;
