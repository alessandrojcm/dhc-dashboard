import { form, getRequestEvent } from "$app/server";
import {
	workshopsCreate,
	workshopsShow,
	workshopsUpdate,
	type WorkshopManagementRequest,
	type WorkshopManagementUpdateRequest,
} from "@dhc/api-client";
import Dinero from "dinero.js";
import { authorize } from "#lib/server/auth.js";
import { apiErrorMessage, type ApiFieldMessages } from "#lib/api-error.js";
import {
	type CommandIssue,
	type FieldAttribution,
	commandResult,
} from "#lib/server/api/command-result.js";
import { apiClientOptions } from "#lib/server/api-client.js";
import {
	CreateWorkshopRemoteSchema,
	UpdateWorkshopRemoteSchema,
	movesOntoDublinToday,
	startsDublinToday,
} from "#lib/schemas/workshop.js";

/**
 * ALE-440: Phoenix names destination rejections by their public camelCase
 * request field; each becomes that form field's issue so the entered values
 * survive the rejection beside the message. Any other field name finds no
 * mapping here.
 */
function destinationFormField(
	field: string,
):
	| "destination_name"
	| "destination_address"
	| "directions_url"
	| "destination_place_id"
	| undefined {
	switch (field) {
		case "destinationName":
			return "destination_name";
		case "destinationAddress":
			return "destination_address";
		case "directionsUrl":
			return "directions_url";
		// ALE-442: a refused selection is shown on the selected place.
		case "destinationPlaceId":
			return "destination_place_id";
	}
}

type DestinationIssueBuilder = (message: string) => CommandIssue;

interface DestinationIssueRoot {
	destination_name: DestinationIssueBuilder;
	destination_address: DestinationIssueBuilder;
	directions_url: DestinationIssueBuilder;
	destination_place_id: DestinationIssueBuilder;
}

function attributeDestinationRejection(issue: DestinationIssueRoot) {
	return (fields: ApiFieldMessages[]): FieldAttribution => {
		const issues: CommandIssue[] = [];
		let unattributed = false;

		for (const { field, messages } of fields) {
			const formField = destinationFormField(field);

			if (!formField) {
				unattributed = true;
				continue;
			}

			issues.push(...messages.map((message) => issue[formField](message)));
		}

		return { issues, unattributed };
	};
}

/**
 * Destination fields for the request body: an omitted field (`undefined`)
 * preserves the stored detail, an emptied field clears it (`null`), and a
 * value passes through. The edit form always submits the fields it
 * prefilled, so an unrelated edit resubmits the stored values.
 *
 * ALE-442: the selected Google Place ID follows the same rule; it is the
 * only part of a Google selection ever sent.
 */
function destinationPayload(data: {
	destination_name?: string;
	destination_address?: string;
	directions_url?: string;
	destination_place_id?: string;
}): Pick<
	WorkshopManagementUpdateRequest,
	| "destinationName"
	| "destinationAddress"
	| "directionsUrl"
	| "destinationPlaceId"
> {
	const payload: Pick<
		WorkshopManagementUpdateRequest,
		| "destinationName"
		| "destinationAddress"
		| "directionsUrl"
		| "destinationPlaceId"
	> = {
		destinationName:
			data.destination_name === undefined
				? undefined
				: data.destination_name || null,
		destinationAddress:
			data.destination_address === undefined
				? undefined
				: data.destination_address || null,
		directionsUrl:
			data.directions_url === undefined
				? undefined
				: data.directions_url || null,
	};

	if (data.destination_place_id !== undefined)
		payload.destinationPlaceId = data.destination_place_id.trim() || null;

	return payload;
}

export const createWorkshop = form(
	CreateWorkshopRemoteSchema,
	async (data, issue) => {
		const event = getRequestEvent();
		await authorize(event.locals, "workshops.manage");

		// Cross-field validations
		const startDate = new Date(data.workshop_date);
		const endDate = new Date(data.workshop_end_date);

		if (startsDublinToday(startDate)) {
			throw new Error("Workshop cannot be scheduled for today");
		}

		if (!(endDate.getTime() > startDate.getTime())) {
			throw new Error("End time cannot be before start time");
		}

		// Normalise the submitted instants to ISO strings and prices to cents
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
			...destinationPayload(data),
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

		const result = await commandResult(
			workshopsCreate({
				...apiClientOptions(event.cookies),
				body: workshopData,
			}),
			"Failed to create workshop. Please try again later.",
			attributeDestinationRejection(issue),
		);

		if (!result.ok) {
			throw new Error(result.error);
		}

		const workshop = result.data.workshop;

		return {
			success: `Workshop "${workshop.title}" created successfully!`,
			workshopId: workshop.id,
		};
	},
);

export const updateWorkshop = form(
	UpdateWorkshopRemoteSchema,
	async (data, issue) => {
		const event = getRequestEvent();
		await authorize(event.locals, "workshops.manage");
		const workshopId = event.params.id;

		if (!workshopId) {
			throw new Error("Workshop ID is required");
		}

		// The form submits the start on every save, so judge a start on Dublin's
		// today against the saved one: moving a workshop onto today is refused,
		// like scheduling it for today, but a workshop already taking place today
		// can still be edited. Only a start on today costs the extra read.
		if (data.workshop_date) {
			const now = new Date();
			const start = new Date(data.workshop_date);
			if (startsDublinToday(start, now)) {
				const current = await workshopsShow({
					...apiClientOptions(event.cookies),
					path: { workshopId },
				});
				if (current.error) {
					throw new Error(
						apiErrorMessage(
							current.error,
							"Failed to update workshop. Please try again later.",
						),
					);
				}
				const persisted = new Date(current.data.data.workshop.startDate);
				if (movesOntoDublinToday(start, persisted, now)) {
					throw new Error("Workshop cannot be scheduled for today");
				}
			}
		}

		// Transform form data to database format
		const updateData: WorkshopManagementUpdateRequest = {
			title: data.title,
			description: data.description || null,
			location: data.location,
			// The edit form submits the destination fields it prefilled, so an
			// unrelated edit resubmits the stored values (preserving them) and an
			// emptied field is an explicit clear (null).
			...destinationPayload(data),
			// Pass the submitted instants through untouched: the form keeps both
			// fields coherent when only the date or only the time changes. Do NOT
			// rebuild endDate from startDate plus endDate's local time-of-day — that
			// silently drops a midnight rollover whenever the Workshop crosses days,
			// producing an end_date before start_date.
			startDate: data.workshop_date
				? new Date(data.workshop_date).toISOString()
				: undefined,
			endDate: data.workshop_end_date
				? new Date(data.workshop_end_date).toISOString()
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

		const result = await commandResult(
			workshopsUpdate({
				...apiClientOptions(event.cookies),
				path: { workshopId },
				body: updateData,
			}),
			"Failed to update workshop. Please try again later.",
			attributeDestinationRejection(issue),
		);

		if (!result.ok) {
			throw new Error(result.error);
		}

		const workshop = result.data.workshop;

		return { success: `Workshop "${workshop.title}" updated successfully!` };
	},
);
