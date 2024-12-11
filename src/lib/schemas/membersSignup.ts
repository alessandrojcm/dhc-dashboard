import beginnersWaitlist from './beginnersWaitlist';
import parsePhoneNumber from 'libphonenumber-js';

import * as v from 'valibot';

export const memberSignupSchema = v.object({
	nextOfKin: v.pipe(v.string(), v.nonEmpty('Please enter your next of kin.')),
	nextOfKinNumber: v.pipe(
		v.string(),
		v.nonEmpty('Phone number of your next of kin is required.'),
		v.check((input) => Boolean(parsePhoneNumber(input, 'IE')?.isValid), 'Invalid phone number'),
		v.transform((input) => parsePhoneNumber(input, 'IE')!.formatInternational())
	),
	insuranceFormSubmitted: v.pipe(
		v.boolean('Please confirm you have read and accepted the insurance form.'),
		v.check((input) => input, 'Please confirm you have read and accepted the insurance form.')
	)
});

const formSchema = v.object({
	...beginnersWaitlist.entries,
	...memberSignupSchema.entries,
	weapon: v.array(v.string('Please select your preferred weapon.')),
});


export default formSchema;
export type SignupForm = v.InferInput<typeof formSchema>;
export type MemberSignupForm = v.InferInput<typeof memberSignupSchema>;
