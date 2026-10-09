/**
 * ALE-378: the Workshops tab commands. Thin adapters — authorize, make one
 * generated Phoenix call, translate the problem — with the schema in
 * `#lib/schemas/beginnersWorkshop.js`. Phoenix owns every default and rule.
 */
import { form } from "$app/server";
import {
	beginnersWorkshopsSchedule,
	beginnersWorkshopsUpdateSettings,
} from "@dhc/api-client";
import {
	scheduleWorkshopsSchema,
	workshopSettingsSchema,
} from "#lib/schemas/beginnersWorkshop.js";
import { beginnersWorkshopCommand } from "#lib/server/beginners-workshops/command.js";
import {
	scheduleFormPath,
	settingsFormPath,
} from "#lib/server/beginners-workshops/form-paths.js";
import { beginnersWorkshopsManageOptions } from "#lib/server/beginners-workshops/options.js";

export const scheduleWorkshops = form(scheduleWorkshopsSchema, async (body) => {
	const options = await beginnersWorkshopsManageOptions();
	return beginnersWorkshopCommand(
		beginnersWorkshopsSchedule({ ...options, body }),
		{
			fallback: "Could not schedule the workshops",
			formPath: scheduleFormPath,
		},
	);
});

export const updateWorkshopSettings = form(
	workshopSettingsSchema,
	async ({ id, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopsUpdateSettings({ ...options, path: { id }, body }),
			{
				fallback: "Could not save the workshop settings",
				formPath: settingsFormPath,
			},
		);
	},
);
