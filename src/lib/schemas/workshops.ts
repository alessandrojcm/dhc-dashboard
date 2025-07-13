import * as v from 'valibot';
import dayjs from 'dayjs';

const isToday = (date: Date) => dayjs(date).isSame(dayjs(), 'day');

export const CreateWorkshopSchema = v.pipe(
	v.object({
		title: v.pipe(v.string(), v.minLength(1, 'Title is required'), v.maxLength(255)),
		description: v.optional(v.string(), ''),
		location: v.pipe(v.string(), v.minLength(1, 'Location is required')),
		workshop_date: v.pipe(
			v.date(),
			v.check((date) => !isToday(date), 'Workshop cannot be scheduled for today')
		),
		workshop_end_date: v.date(),
		max_capacity: v.pipe(v.number(), v.minValue(1, 'Capacity must be at least 1')),
		price_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
		price_non_member: v.optional(v.pipe(v.number(), v.minValue(0, 'Price cannot be negative'))),
		is_public: v.optional(v.boolean(), false),
		refund_deadline_days: v.nullable(
			v.pipe(v.number(), v.minValue(0, 'Refund deadline cannot be negative'))
		)
	}),
	v.forward(
		v.partialCheck(
			[['workshop_date'], ['workshop_end_date']],
			({ workshop_date, workshop_end_date }) => {
				return dayjs(workshop_end_date).isAfter(dayjs(workshop_date));
			},
			'End time cannot be before start time'
		),
		['workshop_end_date']
	)
);

export const UpdateWorkshopSchema = v.partial(CreateWorkshopSchema);

export type CreateWorkshopData = v.InferInput<typeof CreateWorkshopSchema>;
export type UpdateWorkshopData = v.InferInput<typeof UpdateWorkshopSchema>;
