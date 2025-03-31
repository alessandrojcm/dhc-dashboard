import beginnersWaitlist from './beginnersWaitlist';

import * as v from 'valibot';
import { phoneNumberValidator } from './commonValidators';

export const memberSignupSchema = v.object({
	nextOfKin: v.pipe(v.string(), v.nonEmpty('Please enter your next of kin.')),
	nextOfKinNumber: phoneNumberValidator('Phone number of your next of kin is required.'),
	insuranceFormSubmitted: v.pipe(
		v.boolean('Please confirm you have read and accepted the insurance form.'),
		v.check((input) => input, 'Please confirm you have read and accepted the insurance form.')
	),
	stripeConfirmationToken: v.pipe(
		v.string(),
		v.nonEmpty('Something has gone wrong with your payment, please try again.')
	)
});

const formSchema = v.object({
	...beginnersWaitlist.entries,
	...v.omit(memberSignupSchema, ['stripeConfirmationToken']).entries,
	weapon: v.array(v.string('Please select your preferred weapon.'))
});

export default formSchema;
export type SignupForm = v.InferInput<typeof formSchema>;
export type MemberSignupForm = v.InferInput<typeof memberSignupSchema>;
