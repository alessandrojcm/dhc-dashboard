import { form, getRequestEvent } from "$app/server";
import {
	inventoryCategoriesCreate,
	inventoryCategoriesUpdate,
	inventoryStructureCreateDefinition,
	inventoryStructureCreateOption,
	inventoryStructureUpdateDefinition,
	inventoryStructureUpdateOption,
	vInventoryCategoryCreateRequest,
	vInventoryDefinitionUpdateRequest,
	vInventoryOptionCreateRequest,
	vInventoryOptionUpdateRequest,
} from "@dhc/api-client";
import { apiErrorMessage } from "$lib/api-error";
import { apiClientOptions } from "$lib/server/api-client";
import { authorize } from "$lib/server/auth";
import * as v from "valibot";

const uuid = v.pipe(v.string(), v.uuid("Choose a valid record"));
const optionalId = v.pipe(
	v.string(),
	v.transform((value) => value || undefined),
	v.optional(uuid),
);
const trimmedString = v.pipe(
	v.string(),
	v.transform((value) => value.trim()),
);
const categoryFields = vInventoryCategoryCreateRequest.entries;
const definitionUpdateFields = vInventoryDefinitionUpdateRequest.entries;
const optionCreateFields = vInventoryOptionCreateRequest.entries;
const optionUpdateFields = vInventoryOptionUpdateRequest.entries;
const nullablePosition = v.pipe(
	trimmedString,
	v.transform((value) => (value === "" ? null : Number(value))),
	v.nullable(v.pipe(v.number(), v.integer(), v.minValue(0))),
);

const categoryFormSchema = v.object({
	id: optionalId,
	name: v.pipe(trimmedString, categoryFields.name),
	description: v.pipe(
		trimmedString,
		v.transform((value) => value || null),
		v.nullable(v.unwrap(categoryFields.description)),
	),
});

const definitionFormSchema = v.object({
	categoryId: uuid,
	definitionId: optionalId,
	label: v.pipe(trimmedString, v.unwrap(definitionUpdateFields.label)),
	valueType: v.unwrap(definitionUpdateFields.valueType),
	required: v.picklist(["true", "false"]),
	identifyingPosition: v.pipe(
		nullablePosition,
		v.nullable(v.unwrap(definitionUpdateFields.identifyingPosition)),
	),
});

const optionFormSchema = v.object({
	definitionId: uuid,
	label: v.pipe(trimmedString, optionCreateFields.label),
});
const optionUpdateFormSchema = v.object({
	optionId: uuid,
	label: v.pipe(trimmedString, v.unwrap(optionUpdateFields.label)),
	position: v.pipe(
		v.string(),
		v.transform(Number),
		v.unwrap(optionUpdateFields.position),
	),
});

function failure(cause: unknown, fallback: string) {
	return { ok: false as const, error: apiErrorMessage(cause, fallback) };
}

async function requestOptions() {
	const event = getRequestEvent();
	await authorize(event.locals, "inventory.manage");
	return apiClientOptions(event.cookies);
}

export const saveCategory = form(
	categoryFormSchema,
	async ({ id, ...fields }) => {
		const options = await requestOptions();
		const response = id
			? await inventoryCategoriesUpdate({
					...options,
					path: { id },
					body: fields,
				})
			: await inventoryCategoriesCreate({ ...options, body: fields });
		if (response.error)
			return failure(
				response.error,
				`Could not ${id ? "update" : "create"} category`,
			);
		return { ok: true as const, data: response.data.data, created: !id };
	},
);

export const saveDefinition = form(
	definitionFormSchema,
	async ({ categoryId, definitionId, required, ...fields }) => {
		const options = await requestOptions();
		const fieldsWithRequired = {
			...fields,
			required: required === "true",
		};
		const response = definitionId
			? await inventoryStructureUpdateDefinition({
					...options,
					path: { id: definitionId },
					body: fieldsWithRequired,
				})
			: await inventoryStructureCreateDefinition({
					...options,
					path: { categoryId },
					body: fieldsWithRequired,
				});
		if (response.error)
			return failure(
				response.error,
				`Could not ${definitionId ? "update" : "create"} property`,
			);
		return {
			ok: true as const,
			data: response.data.data,
			created: !definitionId,
		};
	},
);

export const createOption = form(
	optionFormSchema,
	async ({ definitionId, ...fields }) => {
		const response = await inventoryStructureCreateOption({
			...(await requestOptions()),
			path: { definitionId },
			body: fields,
		});
		if (response.error)
			return failure(response.error, "Could not create option");
		return { ok: true as const, data: response.data.data };
	},
);

export const updateOption = form(
	optionUpdateFormSchema,
	async ({ optionId, ...fields }) => {
		const response = await inventoryStructureUpdateOption({
			...(await requestOptions()),
			path: { id: optionId },
			body: fields,
		});
		if (response.error)
			return failure(response.error, "Could not update option");
		return { ok: true as const, data: response.data.data };
	},
);
