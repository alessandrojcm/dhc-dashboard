import { command, query, getRequestEvent } from "$app/server";
import { error } from "@sveltejs/kit";
import * as v from "valibot";
import { authorize } from "$lib/server/auth";
import { WORKSHOP_ROLES } from "$lib/server/roles";
import {
	createWorkshopService,
	createAttendanceService,
	createRefundService,
} from "../server/services/workshops";
import { executeWithRLS, getKyselyClient } from "../server/services/shared";

export const deleteWorkshop = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const { locals, platform } = getRequestEvent();
		const session = await authorize(locals, WORKSHOP_ROLES);
		const service = createWorkshopService(platform!, session);
		await service.delete(workshopId);
		return { success: true as const };
	},
);

export const publishWorkshop = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const { locals, platform } = getRequestEvent();
		const session = await authorize(locals, WORKSHOP_ROLES);
		const service = createWorkshopService(platform!, session);
		const workshop = await service.publish(workshopId);
		return { success: true as const, workshop };
	},
);

export const cancelWorkshop = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const { locals, platform } = getRequestEvent();
		const session = await authorize(locals, WORKSHOP_ROLES);
		const service = createWorkshopService(platform!, session);
		const workshop = await service.cancel(workshopId);
		return { success: true as const, workshop };
	},
);

export const getWorkshopAttendance = query(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const { locals, platform } = getRequestEvent();
		const session = await authorize(locals, WORKSHOP_ROLES);
		const service = createAttendanceService(platform!, session);
		const attendance = await service.getWorkshopAttendance(workshopId);
		return { success: true as const, attendance };
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
		const { locals, platform } = getRequestEvent();
		const session = await authorize(locals, WORKSHOP_ROLES);
		const service = createAttendanceService(platform!, session);
		const registrations = await service.updateAttendance(
			workshopId,
			attendance_updates,
		);
		return { success: true as const, registrations };
	},
);

export const getWorkshopRefunds = query(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const { locals, platform } = getRequestEvent();
		const session = await authorize(locals, WORKSHOP_ROLES);
		const service = createRefundService(platform!, session);
		const refunds = await service.getWorkshopRefunds(workshopId);
		return { success: true as const, refunds };
	},
);

export const processRefund = command(
	v.object({
		registration_id: v.pipe(v.string(), v.uuid()),
		reason: v.pipe(
			v.string(),
			v.minLength(1, "Reason is required"),
			v.maxLength(500, "Reason must be less than 500 characters"),
		),
	}),
	async ({ registration_id, reason }) => {
		const { locals, platform } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const kysely = getKyselyClient(platform!.env.HYPERDRIVE);
		const registration = await executeWithRLS(
			kysely,
			{ claims: session },
			async (trx) => {
				return await trx
					.selectFrom("club_activity_registrations")
					.select(["member_user_id"])
					.where("id", "=", registration_id)
					.executeTakeFirst();
			},
		);

		if (!registration) {
			error(404, "Registration not found");
		}

		const isOwner = registration.member_user_id === session.user.id;

		if (!isOwner) {
			try {
				await authorize(locals, WORKSHOP_ROLES);
			} catch {
				error(403, "You can only request refunds for your own registrations");
			}
		}

		const service = createRefundService(platform!, session);
		const refund = await service.processRefund(registration_id, reason);
		return { success: true as const, refund };
	},
);
