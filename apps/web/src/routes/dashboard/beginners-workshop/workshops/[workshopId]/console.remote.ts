/**
 * ALE-380: Pause / Resume automatic Batches from the workshop console, and
 * (ALE-384) Fast-track. Thin adapters — authorize, one generated Phoenix
 * call, translate the problem. Coordinators never send a Batch: the system
 * sweep does.
 */
import { form } from "$app/server";
import {
	beginnersWorkshopBatchesPause,
	beginnersWorkshopBatchesResume,
	beginnersWorkshopFastTrackNewPerson,
	beginnersWorkshopFastTrackWaitlistPerson,
} from "@dhc/api-client";
import {
	batchesCommandSchema,
	fastTrackNewPersonSchema,
	fastTrackWaitlistPersonSchema,
} from "#lib/schemas/beginnersWorkshop.js";
import { beginnersWorkshopCommand } from "#lib/server/beginners-workshops/command.js";
import { newPersonFormPath } from "#lib/server/beginners-workshops/form-paths.js";
import { beginnersWorkshopsManageOptions } from "#lib/server/beginners-workshops/options.js";

const noFormFields = () => undefined;

export const pauseBatches = form(batchesCommandSchema, async ({ id }) => {
	const options = await beginnersWorkshopsManageOptions();
	return beginnersWorkshopCommand(
		beginnersWorkshopBatchesPause({ ...options, path: { id } }),
		{ fallback: "Could not pause Batches", formPath: noFormFields },
	);
});

export const resumeBatches = form(batchesCommandSchema, async ({ id }) => {
	const options = await beginnersWorkshopsManageOptions();
	return beginnersWorkshopCommand(
		beginnersWorkshopBatchesResume({ ...options, path: { id } }),
		{ fallback: "Could not resume Batches", formPath: noFormFields },
	);
});

export const fastTrackWaitlistPerson = form(
	fastTrackWaitlistPersonSchema,
	async ({ id, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopFastTrackWaitlistPerson({
				...options,
				path: { id },
				body,
			}),
			{ fallback: "Could not fast-track this person", formPath: noFormFields },
		);
	},
);

export const fastTrackNewPerson = form(
	fastTrackNewPersonSchema,
	async ({ id, body }) => {
		const options = await beginnersWorkshopsManageOptions();
		return beginnersWorkshopCommand(
			beginnersWorkshopFastTrackNewPerson({ ...options, path: { id }, body }),
			{
				fallback: "Could not add and fast-track this person",
				formPath: newPersonFormPath,
			},
		);
	},
);
