/**
 * Inventory Container management remote forms — ALE-106.
 *
 * These forms previously routed through the Kysely `ContainerService`
 * (Supabase RLS). They now POST/PATCH/DELETE through the generated
 * `@dhc/api-client` Phoenix endpoints (`inventoryContainersCreate` /
 * `inventoryContainersUpdate` / `inventoryContainersDelete`), carrying the
 * user's Supabase JWT as the bearer. The Phoenix `:inventory_admin_api`
 * pipeline enforces the write-role check (`quartermaster`/`president`/`admin`);
 * `authorize()` is still called here so the SvelteKit layer 403s before
 * reaching the network when the role is missing.
 *
 * The form schema (`containerSchema` from `$lib/schemas/inventory`) validates
 * the snake_case shape the UI emits (`parent_container_id`). The OpenAPI
 * contract uses a camelCase payload key (`parentContainerId`); the `toApiBody`
 * helper performs that translation before calling the SDK.
 *
 * `delete_container` previously checked `itemCount` client-side and threw;
 * the Phoenix API now returns `409` when the container still contains items,
 * so this handler surfaces the API `errors.detail` instead. The server also
 * enforces circular-parent prevention on update, surfacing as a `422` error
 * detail — the UI additionally filters available parents client-side (see
 * the edit page load).
 *
 * Reads (list/show) are consumed browser-side via `inventoryContainersIndex`
 * / server-side via `inventoryContainersShow` in the route load functions.
 */

import { form, getRequestEvent } from "$app/server";
import { redirect } from "@sveltejs/kit";
import * as v from "valibot";
import {
	inventoryContainersCreate,
	inventoryContainersDelete,
	inventoryContainersUpdate,
	type InventoryContainerCreateRequest,
} from "@dhc/api-client";
import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { containerSchema } from "$lib/schemas/inventory";

type ContainerFormData = v.InferOutput<typeof containerSchema>;

/**
 * Translate a valibot-validated form payload (snake_case, the shape the form
 * emits) to the camelCase `InventoryContainerCreateRequest` the OpenAPI
 * contract expects. An empty-string `parent_container_id` (the form's "no
 * parent" value) is emitted as `parentContainerId: null` so the API detaches
 * the container to the root level; an undefined/absent value is omitted so a
 * PATCH leaves the parent unchanged.
 */
function toApiBody(data: ContainerFormData): InventoryContainerCreateRequest {
	const parentId =
		data.parent_container_id && data.parent_container_id.length > 0
			? data.parent_container_id
			: null;
	return {
		name: data.name,
		...(data.description ? { description: data.description } : {}),
		...(data.parent_container_id !== undefined
			? { parentContainerId: parentId }
			: {}),
	};
}

export const createContainer = form(containerSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, INVENTORY_ROLES);

	const response = await inventoryContainersCreate({
		...apiClientOptions(session),
		body: toApiBody(data),
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to create container. Please try again later.",
		);
	}

	redirect(303, `/dashboard/inventory/containers/${response.data.data.id}`);
});

export const updateContainer = form(containerSchema, async (data) => {
	const event = getRequestEvent();
	const containerId = event.params.id;
	const session = await authorize(event.locals, INVENTORY_ROLES);

	const response = await inventoryContainersUpdate({
		...apiClientOptions(session),
		path: { id: containerId! },
		body: toApiBody(data),
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to update container. Please try again later.",
		);
	}

	redirect(303, `/dashboard/inventory/containers/${containerId}`);
});

export const deleteContainer = form(v.object({}), async () => {
	const event = getRequestEvent();
	const containerId = event.params.id;
	const session = await authorize(event.locals, INVENTORY_ROLES);

	const response = await inventoryContainersDelete({
		...apiClientOptions(session),
		path: { id: containerId! },
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to delete container. Please try again later.",
		);
	}

	redirect(303, "/dashboard/inventory/containers");
});
