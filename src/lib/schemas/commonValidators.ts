import dayjs from 'dayjs';
import { parsePhoneNumber } from 'libphonenumber-js/min';
import * as v from 'valibot';

export const phoneNumberValidator = (nomEmptyMessage: string = 'Phone number is required.') =>
	v.pipe(
		v.string(),
		v.nonEmpty(nomEmptyMessage),
		v.check((input) => {
			if (input === '') return false;
			return Boolean(parsePhoneNumber(input ?? '', 'IE')?.isValid());
		}, 'Invalid phone number'),
		v.transform((input) => parsePhoneNumber(input ?? '', 'IE')!.formatInternational())
	);

export const dobValidator = v.pipe(
	v.date('Date of birth is required.'),
	v.check((input) => dayjs().diff(input, 'years') >= 16, 'You must be at least 16 years old.')
);
