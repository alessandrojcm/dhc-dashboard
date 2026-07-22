import { command, query, getRequestEvent } from "$app/server";
import {
	workshopsCancel,
	workshopsDelete,
	workshopsPublish,
	type ApiErrorResponse,
} from "@dhc/api-client";
import * as v from "valibot";
import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import {
	submitWorkshopAttendance,
	type WorkshopAttendanceUpdate,
} from "$lib/server/api/workshop-attendance";
import {
	listWorkshopRefunds,
	submitWorkshopRefund,
} from "$lib/server/api/workshop-refunds";
import { WORKSHOP_ROLES } from "$lib/server/roles";

function apiErrorMessage(error: unknown, fallback: string) {
	return (error as ApiErrorResponse | undefined)?.errors?.detail ?? fallback;
}

/**
 * ALE-164: the dashboard authenticates through the Phoenix `_dhc_session`
 * cookie. Remote functions forward the cookie to Phoenix via
 * `apiClientOptions(event.cookies)`; the prior `apiClientOptions(session)`
 * pattern (which carried the Supabase `access_token`) is removed.
 */

export const deleteWorkshop = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const event = getRequestEvent();
		await authorize(event.locals, WORKSHOP_ROLES);
		const response = await workshopsDelete({
			...apiClientOptions(event.cookies),
			path: { workshopId },
		});

		if (response.error) {
			throw new Error(
				apiErrorMessage(
					response.error,
					"Failed to delete workshop. Please try again later.",
				),
			);
		}

		return { success: true as const };
	},
);

export const publishWorkshop = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const event = getRequestEvent();
		await authorize(event.locals, WORKSHOP_ROLES);
		const response = await workshopsPublish({
			...apiClientOptions(event.cookies),
			path: { workshopId },
		});

		if (response.error) {
			throw new Error(
				apiErrorMessage(
					response.error,
					"Failed to publish workshop. Please try again later.",
				),
			);
		}

		const workshop = response.data.data.workshop;
		return { success: true as const, workshop };
	},
);

export const cancelWorkshop = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const event = getRequestEvent();
		await authorize(event.locals, WORKSHOP_ROLES);
		const response = await workshopsCancel({
			...apiClientOptions(event.cookies),
			path: { workshopId },
		});

		if (response.error) {
			throw new Error(
				apiErrorMessage(
					response.error,
					"Failed to cancel workshop. Please try again later.",
				),
			);
		}

		const workshop = response.data.data.workshop;
		return { success: true as const, workshop };
	},
);

export const updateAttendance = command(
	v.object({
		workshopId: v.pipe(v.string(), v.uuid()),
		attendance_updates: v.pipe(
			v.array(
				v.object({
					registration_id: v.pipe(v.string(), v.uuid()),
					attendance_status: v.picklist(["attended", "no_show", "excused"]),
					notes: v.optional(
						v.pipe(
							v.string(),
							v.maxLength(500, "Notes must be less than 500 characters"),
						),
					),
				}),
			),
			v.minLength(1, "At least one attendance update required"),
		),
	}),
	async ({ workshopId, attendance_updates }) => {
		const event = getRequestEvent();
		await authorize(event.locals, WORKSHOP_ROLES);
		const registrations = await submitWorkshopAttendance(event.cookies, {
			workshopId,
			updates: attendance_updates.map(
				(update): WorkshopAttendanceUpdate => ({
					registrationId: update.registration_id,
					attendanceStatus:
						update.attendance_status === "no_show"
							? "noShow"
							: update.attendance_status,
					notes: update.notes,
				}),
			),
		});
		return { success: true as const, registrations };
	},
);

export const getWorkshopRefunds = query(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const event = getRequestEvent();
		await authorize(event.locals, WORKSHOP_ROLES);
		const refunds = await listWorkshopRefunds(event.cookies, workshopId);
		return { success: true as const, refunds };
	},
);

export const processRefund = command(
	v.object({
		workshopId: v.pipe(v.string(), v.uuid()),
		registration_id: v.pipe(v.string(), v.uuid()),
		reason: v.pipe(
			v.string(),
			v.minLength(1, "Reason is required"),
			v.maxLength(500, "Reason must be less than 500 characters"),
		),
	}),
	async ({ workshopId, registration_id, reason }) => {
		const event = getRequestEvent();
		await authorize(event.locals, WORKSHOP_ROLES);
		const refund = await submitWorkshopRefund(event.cookies, {
			workshopId,
			registrationId: registration_id,
			reason,
		});
		return { success: true as const, refund };
	},
);
