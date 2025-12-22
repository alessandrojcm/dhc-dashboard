import { form, getRequestEvent } from '$app/server';
import { redirect } from '@sveltejs/kit';
import * as v from 'valibot';
import dayjs from 'dayjs';
import Dinero from 'dinero.js';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { createWorkshopService, type WorkshopUpdate } from '$lib/server/services/workshops';

// ============================================================================
// Remote-compatible schemas using string dates
// (Remote Functions don't support Date objects or null values in schemas)
// Cross-field validation (e.g., end time after start time) is done in handlers
// ============================================================================

// Simple schema without cross-field validation (validation done in handler)
const CreateWorkshopRemoteSchema = v.object({
	title: v.pipe(v.string(), v.minLength(1, 'Title is required'), v.maxLength(255)),
	description: v.optional(v.string(), ''),
	location: v.pipe(v.string(), v.minLength(1, 'Location is required')),
	workshop_date: v.pipe(v.string(), v.nonEmpty('Workshop date is required')),
	workshop_end_date: v.pipe(v.string(), v.nonEmpty('Workshop end date is required')),
	max_capacity: v.pipe(v.number(), v.minValue(1, 'Capacity must be at least 1')),
	price_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
	price_non_member: v.optional(v.pipe(v.number(), v.minValue(0, 'Price cannot be negative'))),
	is_public: v.optional(v.boolean(), false),
	refund_deadline_days: v.optional(
		v.pipe(v.number(), v.minValue(0, 'Refund deadline cannot be negative'))
	),
	announce_discord: v.optional(v.boolean(), false),
	announce_email: v.optional(v.boolean(), false)
});

const UpdateWorkshopRemoteSchema = v.partial(
	v.object({
		title: v.pipe(v.string(), v.minLength(1, 'Title is required'), v.maxLength(255)),
		description: v.optional(v.string(), ''),
		location: v.pipe(v.string(), v.minLength(1, 'Location is required')),
		workshop_date: v.pipe(v.string(), v.nonEmpty('Workshop date is required')),
		workshop_end_date: v.pipe(v.string(), v.nonEmpty('Workshop end date is required')),
		max_capacity: v.pipe(v.number(), v.minValue(1, 'Capacity must be at least 1')),
		price_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
		price_non_member: v.optional(v.pipe(v.number(), v.minValue(0, 'Price cannot be negative'))),
		is_public: v.optional(v.boolean(), false),
		refund_deadline_days: v.optional(
			v.pipe(v.number(), v.minValue(0, 'Refund deadline cannot be negative'))
		)
	})
);

// ============================================================================
// Remote Form Functions
// ============================================================================

export const createWorkshop = form(CreateWorkshopRemoteSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, WORKSHOP_ROLES);

	// Cross-field validations
	const startDate = dayjs(data.workshop_date);
	const endDate = dayjs(data.workshop_end_date);

	if (startDate.isSame(dayjs(), 'day')) {
		throw new Error('Workshop cannot be scheduled for today');
	}

	if (!endDate.isAfter(startDate)) {
		throw new Error('End time cannot be before start time');
	}

	// Transform string dates to ISO strings and prices to cents
	const startDateTime = startDate.toISOString();
	const endDateTime = endDate.toISOString();

	const memberPriceCents = Dinero({
		amount: Math.round(data.price_member * 100),
		currency: 'EUR'
	}).getAmount();

	const nonMemberPriceCents =
		data.is_public && data.price_non_member
			? Dinero({
					amount: Math.round(data.price_non_member * 100),
					currency: 'EUR'
				}).getAmount()
			: memberPriceCents;

	const workshopData = {
		title: data.title,
		description: data.description,
		location: data.location,
		start_date: startDateTime,
		end_date: endDateTime,
		max_capacity: data.max_capacity,
		price_member: memberPriceCents,
		price_non_member: nonMemberPriceCents,
		is_public: data.is_public || false,
		refund_days: data.refund_deadline_days,
		announce_discord: data.announce_discord || false,
		announce_email: data.announce_email || false
	};

	const workshopService = createWorkshopService(event.platform!, session);
	const workshop = await workshopService.create(workshopData);

	redirect(303, `/dashboard/workshops/${workshop.id}`);
});

export const updateWorkshop = form(UpdateWorkshopRemoteSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, WORKSHOP_ROLES);
	const workshopId = event.params.id;

	if (!workshopId) {
		throw new Error('Workshop ID is required');
	}

	const workshopService = createWorkshopService(event.platform!, session);

	// Check if workshop can be edited
	const workshopEditable = await workshopService.canEdit(workshopId);
	if (!workshopEditable) {
		throw new Error('Only planned workshops can be edited');
	}

	// Check if pricing changes are allowed
	const pricingEditable = await workshopService.canEditPricing(workshopId);
	if (!pricingEditable && (data.price_member !== undefined || data.price_non_member !== undefined)) {
		throw new Error('Cannot change pricing when there are already registered attendees');
	}

	// Fetch current workshop for price fallback
	const currentWorkshop = await workshopService.findById(workshopId);

	// Transform form data to database format
	const updateData: WorkshopUpdate = {
		...data,
		start_date: data.workshop_date ? dayjs(data.workshop_date).toISOString() : undefined,
		end_date: data.workshop_end_date
			? (() => {
					const endDate = dayjs(data.workshop_end_date);
					if (data.workshop_date) {
						return dayjs(data.workshop_date)
							.set('hour', endDate.hour())
							.set('minute', endDate.minute())
							.toISOString();
					}
					return endDate.toISOString();
				})()
			: undefined,
		refund_days: data.refund_deadline_days
	};

	// Remove the string date fields from update data
	delete (updateData as Record<string, unknown>).workshop_date;
	delete (updateData as Record<string, unknown>).workshop_end_date;
	delete (updateData as Record<string, unknown>).refund_deadline_days;

	// Convert euro prices to cents only if pricing changes are allowed
	if (pricingEditable) {
		if (typeof data.price_member === 'number') {
			updateData.price_member = Dinero({
				amount: Math.round(data.price_member * 100),
				currency: 'EUR'
			}).getAmount();
		}

		if (typeof data.price_non_member === 'number') {
			updateData.price_non_member =
				data.is_public && data.price_non_member
					? Dinero({
							amount: Math.round(data.price_non_member * 100),
							currency: 'EUR'
						}).getAmount()
					: updateData.price_member || currentWorkshop.price_member;
		}
	}

	const workshop = await workshopService.update(workshopId, updateData);

	return { success: `Workshop "${workshop.title}" updated successfully!` };
});
