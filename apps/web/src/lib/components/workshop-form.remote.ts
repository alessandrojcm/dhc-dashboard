import { form, getRequestEvent } from "$app/server";
import {
	workshopsCreate,
	workshopsUpdate,
	type WorkshopManagementRequest,
	type WorkshopManagementUpdateRequest,
} from "@dhc/api-client";
import Dinero from "dinero.js";
import { authorize } from "$lib/server/auth";
import { apiErrorMessage } from "$lib/server/api-error";
import { apiClientOptions } from "$lib/server/api-client";
import { WORKSHOP_ROLES } from "$lib/server/roles";
import {
	CreateWorkshopRemoteSchema,
	UpdateWorkshopRemoteSchema,
} from "$lib/schemas/workshop";
import dayjs from "dayjs";

export const createWorkshop = form(CreateWorkshopRemoteSchema, async (data) => {
	const event = getRequestEvent();
	await authorize(event.locals, WORKSHOP_ROLES);

	// Cross-field validations
	const startDate = dayjs(data.workshop_date);
	const endDate = dayjs(data.workshop_end_date);

	if (startDate.isSame(dayjs(), "day")) {
		throw new Error("Workshop cannot be scheduled for today");
	}

	if (!endDate.isAfter(startDate)) {
		throw new Error("End time cannot be before start time");
	}

	// Transform string dates to ISO strings and prices to cents
	const startDateTime = startDate.toISOString();
	const endDateTime = endDate.toISOString();

	const memberPriceCents = Dinero({
		amount: Math.round(data.price_member * 100),
		currency: "EUR",
	}).getAmount();

	const nonMemberPriceCents =
		data.is_public && data.price_non_member
			? Dinero({
					amount: Math.round(data.price_non_member * 100),
					currency: "EUR",
				}).getAmount()
			: memberPriceCents;

	const workshopData: WorkshopManagementRequest = {
		title: data.title,
		description: data.description || null,
		location: data.location,
		startDate: startDateTime,
		endDate: endDateTime,
		maxCapacity: data.max_capacity,
		priceMember: memberPriceCents,
		priceNonMember: nonMemberPriceCents,
		isPublic: data.is_public || false,
		refundDays: data.refund_deadline_days ?? 0,
		announceDiscord: data.announce_discord || false,
		announceEmail: data.announce_email || false,
	};

	const response = await workshopsCreate({
		...apiClientOptions(event.cookies),
		body: workshopData,
	});

	if (response.error) {
		throw new Error(
			apiErrorMessage(
				response.error,
				"Failed to create workshop. Please try again later.",
			),
		);
	}

	const workshop = response.data.data.workshop;

	return {
		success: `Workshop "${workshop.title}" created successfully!`,
		workshopId: workshop.id,
	};
});

export const updateWorkshop = form(UpdateWorkshopRemoteSchema, async (data) => {
	const event = getRequestEvent();
	await authorize(event.locals, WORKSHOP_ROLES);
	const workshopId = event.params.id;

	if (!workshopId) {
		throw new Error("Workshop ID is required");
	}

	// Transform form data to database format
	const updateData: WorkshopManagementUpdateRequest = {
		title: data.title,
		description: data.description || null,
		location: data.location,
		startDate: data.workshop_date
			? dayjs(data.workshop_date).toISOString()
			: undefined,
		endDate: data.workshop_end_date
			? (() => {
					const endDate = dayjs(data.workshop_end_date);
					if (data.workshop_date) {
						return dayjs(data.workshop_date)
							.set("hour", endDate.hour())
							.set("minute", endDate.minute())
							.toISOString();
					}
					return endDate.toISOString();
				})()
			: undefined,
		maxCapacity: data.max_capacity,
		isPublic: data.is_public,
		refundDays: data.refund_deadline_days ?? undefined,
	};

	if (data.price_member !== undefined) {
		updateData.priceMember = Dinero({
			amount: Math.round(data.price_member * 100),
			currency: "EUR",
		}).getAmount();
	}

	if (data.price_non_member !== undefined) {
		updateData.priceNonMember =
			data.is_public && data.price_non_member
				? Dinero({
						amount: Math.round(data.price_non_member * 100),
						currency: "EUR",
					}).getAmount()
				: updateData.priceMember;
	}

	const response = await workshopsUpdate({
		...apiClientOptions(event.cookies),
		path: { workshopId },
		body: updateData,
	});

	if (response.error) {
		throw new Error(
			apiErrorMessage(
				response.error,
				"Failed to update workshop. Please try again later.",
			),
		);
	}

	const workshop = response.data.data.workshop;

	return { success: `Workshop "${workshop.title}" updated successfully!` };
});
