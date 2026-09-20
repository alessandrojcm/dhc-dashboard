import { form, getRequestEvent } from "$app/server";
import {
	inventoryContainersCreate,
	inventoryContainersUpdate,
	vInventoryContainerCreateRequest,
} from "@dhc/api-client";
import { apiErrorMessage } from "$lib/api-error";
import { apiClientOptions } from "$lib/server/api-client";
import { authorize } from "$lib/server/auth";
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
	async ({ id, ...fields }) => {
		const event = getRequestEvent();
		await authorize(event.locals, "inventory.manage");
		const options = apiClientOptions(event.cookies);
		const response = id
			? await inventoryContainersUpdate({
					...options,
					path: { id },
					body: fields,
				})
			: await inventoryContainersCreate({ ...options, body: fields });

		if (response.error) {
			return {
				ok: false as const,
				error: apiErrorMessage(
					response.error,
					`Could not ${id ? "update" : "create"} container`,
				),
			};
		}

		return { ok: true as const, data: response.data.data, created: !id };
	},
);
