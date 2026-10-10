/**
 * ALE-380: Pause / Resume automatic Batches from the workshop console. Thin
 * adapters — authorize, one generated Phoenix call, translate the problem.
 * Coordinators never send a Batch: the system sweep does.
 */
import { form } from "$app/server";
import {
	beginnersWorkshopBatchesPause,
	beginnersWorkshopBatchesResume,
} from "@dhc/api-client";
import { batchesCommandSchema } from "#lib/schemas/beginnersWorkshop.js";
import { beginnersWorkshopCommand } from "#lib/server/beginners-workshops/command.js";
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
