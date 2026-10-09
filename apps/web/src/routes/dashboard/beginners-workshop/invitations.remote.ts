/**
 * ALE-392: the Invitation handoff — one attended person, one click, from the
 * console's attended list or the Invitable view. A thin adapter: authorize,
 * one generated Phoenix call, translate the problem. Phoenix decides
 * eligibility and answers a refusal with its named reason, which the row
 * shows.
 */
import { form } from "$app/server";
import { beginnersWorkshopInvitationsInvite } from "@dhc/api-client";
import { inviteAttendeeSchema } from "#lib/schemas/beginnersWorkshop.js";
import { beginnersWorkshopCommand } from "#lib/server/beginners-workshops/command.js";
import { membersInviteOptions } from "#lib/server/beginners-workshops/options.js";

export const inviteAttendee = form(
	inviteAttendeeSchema,
	async ({ id, intakeId }) => {
		const options = await membersInviteOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopInvitationsInvite({
				...options,
				path: { id, intakeId },
			}),
			{ fallback: "Could not send the Invitation", formPath: () => undefined },
		);
	},
);
