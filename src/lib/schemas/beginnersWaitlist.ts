import dayjs from 'dayjs';
import * as v from 'valibot';
import parsePhoneNumber from 'libphonenumber-js';

const formValidation = v.object({
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	email: v.pipe(v.string(), v.nonEmpty('Please enter your email.'), v.email('Email is invalid.')),
	phoneNumber: v.pipe(
		v.string(),
		v.nonEmpty('Phone number is required.'),
		v.check((input) => Boolean(parsePhoneNumber(input, 'IE')?.isValid), 'Invalid phone number'),
		v.transform((input) => parsePhoneNumber(input, 'IE')!.formatInternational())
	),
	dateOfBirth: v.pipe(
		v.date('Date of birth is required.'),
		v.check((input) => dayjs().diff(input, 'years') >= 16, 'You must be at least 16 years old.')
	),
	medicalConditions: v.pipe(v.string())
});

export default formValidation;

export type BeginnersFormSchema = typeof formValidation;
