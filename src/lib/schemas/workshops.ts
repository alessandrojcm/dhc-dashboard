import * as v from 'valibot';

export const CreateWorkshopSchema = v.object({
	title: v.pipe(v.string(), v.minLength(1, 'Title is required'), v.maxLength(255)),
	description: v.optional(v.string(), ''),
	location: v.pipe(v.string(), v.minLength(1, 'Location is required')),
	workshop_date: v.date(),
	workshop_time: v.pipe(v.string(), v.minLength(1, 'Workshop time is required')),
	max_capacity: v.pipe(v.number(), v.minValue(1, 'Capacity must be at least 1')),
	price_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
	price_non_member: v.optional(v.pipe(v.number(), v.minValue(0, 'Price cannot be negative'))),
	is_public: v.optional(v.boolean(), false),
	refund_deadline_days: v.nullable(
		v.pipe(v.number(), v.minValue(0, 'Refund deadline cannot be negative'))
	)
});

export const UpdateWorkshopSchema = v.partial(CreateWorkshopSchema);

export type CreateWorkshopData = v.InferInput<typeof CreateWorkshopSchema>;
export type UpdateWorkshopData = v.InferInput<typeof UpdateWorkshopSchema>;
