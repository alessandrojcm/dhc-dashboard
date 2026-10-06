import { form } from "$app/server";
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
import { inventoryCommand } from "#lib/server/api/inventory-command.js";
import { inventoryManageOptions } from "#lib/server/api/inventory-manage-options.js";
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

export const saveCategory = form(
	categoryFormSchema,
	async ({ id, ...fields }, issue) => {
		const options = await inventoryManageOptions();
		const result = await inventoryCommand(
			id
				? inventoryCategoriesUpdate({ ...options, path: { id }, body: fields })
				: inventoryCategoriesCreate({ ...options, body: fields }),
			{
				fallback: `Could not ${id ? "update" : "create"} category`,
				fields: ["name", "description"],
				issue,
			},
		);
		return result.ok ? { ...result, created: !id } : result;
	},
);

export const saveDefinition = form(
	definitionFormSchema,
	async ({ categoryId, definitionId, required, ...fields }, issue) => {
		const options = await inventoryManageOptions();
		const body = { ...fields, required: required === "true" };
		const result = await inventoryCommand(
			definitionId
				? inventoryStructureUpdateDefinition({
						...options,
						path: { id: definitionId },
						body,
					})
				: inventoryStructureCreateDefinition({
						...options,
						path: { categoryId },
						body,
					}),
			{
				fallback: `Could not ${definitionId ? "update" : "create"} property`,
				fields: ["label", "valueType", "required", "identifyingPosition"],
				issue,
			},
		);
		return result.ok ? { ...result, created: !definitionId } : result;
	},
);

export const createOption = form(
	optionFormSchema,
	async ({ definitionId, ...fields }, issue) =>
		inventoryCommand(
			inventoryStructureCreateOption({
				...(await inventoryManageOptions()),
				path: { definitionId },
				body: fields,
			}),
			{ fallback: "Could not create option", fields: ["label"], issue },
		),
);

export const updateOption = form(
	optionUpdateFormSchema,
	async ({ optionId, ...fields }, issue) =>
		inventoryCommand(
			inventoryStructureUpdateOption({
				...(await inventoryManageOptions()),
				path: { id: optionId },
				body: fields,
			}),
			{
				fallback: "Could not update option",
				fields: ["label", "position"],
				issue,
			},
		),
);
