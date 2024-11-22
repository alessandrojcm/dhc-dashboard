import dayjs from 'dayjs';
import * as v from 'valibot';

const formValidation = v.object({
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	email: v.pipe(
		v.string(),
		v.nonEmpty('Please enter your email.'),
		v.email('The email is badly formatted.'),
		v.maxLength(30, 'Your email is too long.')
	),
	phoneNumber: v.pipe(
		v.string(),
		v.nonEmpty('Phone number is required.')
		// additional phone number validation if needed
	),
	dateOfBirth: v.pipe(
		v.date('Date of birth is required.'),
		v.toMinValue(dayjs().subtract(16, 'year').toDate())
	),
	medicalConditions: v.pipe(v.string())
});

export default formValidation;

export type BeginnersFormSchema = typeof formValidation;
