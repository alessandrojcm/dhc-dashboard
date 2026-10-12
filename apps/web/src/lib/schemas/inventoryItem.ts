/**
 * The quartermaster Item forms (ALE-416), one schema per form, used for both
 * `form(...)` and `.preflight(...)`. Each output is `{ slugOrId?, body }`:
 * the path the command addresses and the Phoenix request body it sends
 * unchanged. Phoenix judges every value against the category's Property
 * Definitions; these schemas only check what one field can know on its own.
 */
import {
	type InventoryMaintenanceEndRequest,
	type InventoryMaintenanceStartRequest,
	type InventoryOperatorItemArchiveRequest,
	type InventoryOperatorItemCategoryRequest,
	type InventoryOperatorItemCreateRequest,
	type InventoryOperatorItemDeleteRequest,
	type InventoryOperatorItemMoveRequest,
	type InventoryOperatorItemUpdateRequest,
	vInventoryMaintenanceEndRequest,
	vInventoryMaintenanceStartRequest,
	vInventoryOperatorItemArchiveRequest,
	vInventoryOperatorItemCreateRequest,
	vInventoryOperatorItemUpdateRequest,
} from "@dhc/api-client";
import * as v from "valibot";
import { decodePropertyDraft } from "#lib/inventory/property-values.js";

/** The item a command addresses: its code or id, as a hidden field. */
const slugOrId = v.pipe(v.string(), v.minLength(1, "An item is required"));

/** A category or container picked from a list. */
const recordId = v.pipe(v.string(), v.uuid("Choose a valid record"));

/** Optional text: trimmed, and blank becomes `null`. */
const optionalText = <TOutput extends string>(
	limit: v.GenericSchema<string, TOutput>,
) =>
	v.pipe(
		v.string(),
		v.trim(),
		v.transform((value) => value || null),
		v.nullable(limit),
	);

/** The property draft, encoded as JSON in one hidden input. */
const propertyValues = v.pipe(
	v.string(),
	v.transform(decodePropertyDraft),
	v.record(
		recordId,
		v.nullable(v.union([v.string(), v.boolean(), v.number()])),
		"Item properties are invalid",
	),
);

const notesFor = {
	create: optionalText(
		v.unwrap(vInventoryOperatorItemCreateRequest.entries.notes),
	),
	update: optionalText(
		v.unwrap(vInventoryOperatorItemUpdateRequest.entries.notes),
	),
};

export const createItemSchema = v.pipe(
	v.object({
		categoryId: recordId,
		containerId: recordId,
		notes: notesFor.create,
		values: propertyValues,
	}),
	v.transform((body) => ({
		body: body satisfies InventoryOperatorItemCreateRequest,
	})),
);

export const updateItemSchema = v.pipe(
	v.object({
		slugOrId,
		notes: notesFor.update,
		values: propertyValues,
	}),
	v.transform(({ slugOrId, ...body }) => ({
		slugOrId,
		body: body satisfies InventoryOperatorItemUpdateRequest,
	})),
);

export const moveItemSchema = v.pipe(
	v.object({ slugOrId, containerId: recordId }),
	v.transform(({ slugOrId, ...body }) => ({
		slugOrId,
		body: body satisfies InventoryOperatorItemMoveRequest,
	})),
);

export const changeItemCategorySchema = v.pipe(
	v.object({ slugOrId, categoryId: recordId, values: propertyValues }),
	v.transform(({ slugOrId, ...body }) => ({
		slugOrId,
		body: body satisfies InventoryOperatorItemCategoryRequest,
	})),
);

export const startItemMaintenanceSchema = v.pipe(
	v.object({
		slugOrId,
		reason: v.pipe(
			v.string(),
			v.trim(),
			vInventoryMaintenanceStartRequest.entries.reason,
		),
	}),
	v.transform(({ slugOrId, ...body }) => ({
		slugOrId,
		body: body satisfies InventoryMaintenanceStartRequest,
	})),
);

export const endItemMaintenanceSchema = v.pipe(
	v.object({
		slugOrId,
		endNote: optionalText(
			v.unwrap(vInventoryMaintenanceEndRequest.entries.endNote),
		),
	}),
	v.transform(({ slugOrId, ...body }) => ({
		slugOrId,
		body: body satisfies InventoryMaintenanceEndRequest,
	})),
);

/**
 * Archive, with the optional note that closes an open Maintenance Period.
 */
export const archiveItemSchema = v.pipe(
	v.object({
		slugOrId,
		reason: optionalText(
			v.unwrap(vInventoryOperatorItemArchiveRequest.entries.reason),
		),
	}),
	v.transform(({ slugOrId, ...body }) => ({
		slugOrId,
		body: body satisfies InventoryOperatorItemArchiveRequest,
	})),
);

export const restoreItemSchema = v.object({ slugOrId });

/**
 * Delete. The form is only reachable from the confirmation dialog, so
 * submitting it is the consent Phoenix asks for as a literal `true`.
 */
export const deleteItemSchema = v.pipe(
	v.object({ slugOrId }),
	v.transform(({ slugOrId }) => ({
		slugOrId,
		body: { confirm: true } satisfies InventoryOperatorItemDeleteRequest,
	})),
);
