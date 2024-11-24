import dayjs from 'dayjs';
import * as v from 'valibot';

const formValidation = v.object({
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	email: v.pipe(v.string(), v.nonEmpty('Please enter your email.'), v.email('Email is invalid.')),
	phoneNumber: v.pipe(
		v.string(),
		v.nonEmpty('Phone number is required.')
		// additional phone number validation if needed
	),
	dateOfBirth: v.pipe(
		v.string('Date of birth is required.'),
		v.check((input) => dayjs().diff(input, 'years') >= 16, 'You must be at least 16 years old.'),
		v.transform((input) => dayjs(input).toISOString())
	),
	medicalConditions: v.pipe(v.string())
});

export default formValidation;

export type BeginnersFormSchema = typeof formValidation;
