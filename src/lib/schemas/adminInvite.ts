import * as v from 'valibot';
import { dobValidator, phoneNumberValidator } from './commonValidators';

const adminInviteSchema = v.object({
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	email: v.pipe(
		v.string(),
		v.nonEmpty('Please enter an email.'),
		v.email('Email is invalid.'),
		v.transform((input) => input.toLowerCase())
	),
	phoneNumber: phoneNumberValidator(),
	dateOfBirth: dobValidator,
	expirationDays: v.pipe(
		v.number(),
		v.integer('Expiration days must be a whole number.'),
		v.minValue(1, 'Expiration must be at least 1 day.'),
		v.maxValue(365, 'Expiration cannot exceed 365 days.')
	)
});

const bulkInviteSchema = v.object({
	invites: v.pipe(v.array(adminInviteSchema), v.minLength(1))
});

export { adminInviteSchema, bulkInviteSchema };
export type BulkInviteSchema = v.InferInput<typeof bulkInviteSchema>;
export type BulkInviteSchemaOutput = v.InferOutput<typeof bulkInviteSchema>;
export type AdminInviteSchema = v.InferInput<typeof adminInviteSchema>;
export type AdminInviteSchemaOutput = v.InferOutput<typeof adminInviteSchema>;
