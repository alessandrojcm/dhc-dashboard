/**
 * ALE-390: door check-in and its undo. Thin adapters — check the member
 * reaches the door route, make one generated Phoenix call, translate the
 * problem. Phoenix decides the assignment-scoped `beginners.workshops.run`
 * against the workshop's Staff (404 for anyone else), the check-in window
 * and the paid-only rule, and answers the refreshed door view.
 */
import { command, getRequestEvent } from "$app/server";
import {
	beginnersWorkshopDoorCheckIn,
	beginnersWorkshopDoorUndoCheckIn,
} from "@dhc/api-client";
import { doorCheckInSchema } from "#lib/schemas/beginnersWorkshop.js";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorize } from "#lib/server/auth.js";
import { beginnersWorkshopCommand } from "#lib/server/beginners-workshops/command.js";

const noFormFields = () => undefined;

async function doorOptions() {
	const event = getRequestEvent();
	await authorize(event.locals, "beginners.workshops.assigned.read");
	return apiClientOptions(event.cookies);
}

export const checkIn = command(doorCheckInSchema, async ({ id, intakeId }) => {
	const options = await doorOptions();
	return beginnersWorkshopCommand(
		beginnersWorkshopDoorCheckIn({ ...options, path: { id, intakeId } }),
		{ fallback: "Could not check this person in", formPath: noFormFields },
	);
});

export const undoCheckIn = command(
	doorCheckInSchema,
	async ({ id, intakeId }) => {
		const options = await doorOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopDoorUndoCheckIn({ ...options, path: { id, intakeId } }),
			{ fallback: "Could not undo this check-in", formPath: noFormFields },
		);
	},
);
