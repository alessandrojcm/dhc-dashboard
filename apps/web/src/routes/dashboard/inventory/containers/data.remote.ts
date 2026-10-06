import { form } from "$app/server";
import {
	inventoryContainersCreate,
	inventoryContainersUpdate,
	vInventoryContainerCreateRequest,
} from "@dhc/api-client";
import { inventoryCommand } from "#lib/server/api/inventory-command.js";
import { inventoryManageOptions } from "#lib/server/api/inventory-manage-options.js";
import * as v from "valibot";

const uuid = v.pipe(v.string(), v.uuid("Choose a valid container"));
const containerFields = vInventoryContainerCreateRequest.entries;
const optionalId = v.pipe(
	v.string(),
	v.transform((value) => value || undefined),
	v.optional(uuid),
);
const containerFormSchema = v.object({
	id: optionalId,
	name: v.pipe(
		v.string(),
		v.transform((value) => value.trim()),
		containerFields.name,
	),
	description: v.pipe(
		v.string(),
		v.transform((value) => value.trim() || null),
		v.nullable(v.unwrap(containerFields.description)),
	),
	parentContainerId: v.pipe(
		v.string(),
		v.transform((value) => value || null),
		v.nullable(v.unwrap(containerFields.parentContainerId)),
	),
});

export const saveContainer = form(
	containerFormSchema,
	async ({ id, ...fields }, issue) => {
		const options = await inventoryManageOptions();
		const result = await inventoryCommand(
			id
				? inventoryContainersUpdate({ ...options, path: { id }, body: fields })
				: inventoryContainersCreate({ ...options, body: fields }),
			{
				fallback: `Could not ${id ? "update" : "create"} container`,
				fields: ["name", "description", "parentContainerId"],
				issue,
			},
		);
		return result.ok ? { ...result, created: !id } : result;
	},
);
