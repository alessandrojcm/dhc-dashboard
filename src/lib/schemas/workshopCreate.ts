import * as v from 'valibot';
import dayjs from 'dayjs';
import { SocialMediaConsent } from '$lib/types';

export const workshopCreateSchema = v.object({
	workshop_date: v.pipe(
		v.string(),
		v.nonEmpty('Date required'),
		v.check((val) => dayjs(val, undefined, true).isValid(), 'Invalid date'),
		v.check(
			(val) => dayjs(val).isAfter(dayjs().subtract(1, 'minute')),
			'Date cannot be in the past'
		)
	),
	location: v.pipe(v.string(), v.nonEmpty('Location required')),
	coach_id: v.pipe(v.string(), v.nonEmpty('Coach required')),
	capacity: v.pipe(v.optional(v.number(), 16), v.minValue(1, 'Capacity must be at least 1')),
	notes_md: v.optional(v.string())
});

export const onboardingSchema = v.object({
	insuranceConfirmed: v.pipe(
		v.boolean(),
		v.check((val) => val === true, 'Insurance form confirmation is required')
	),
	mediaConsent: v.optional(
		v.enum(SocialMediaConsent, 'Please select an option'),
		SocialMediaConsent.no
	),
	signature: v.optional(v.string())
});

export const checkinSchema = v.object({
	workshopId: v.pipe(v.string(), v.uuid()),
	attendeeEmail: v.pipe(v.string(), v.email())
});
