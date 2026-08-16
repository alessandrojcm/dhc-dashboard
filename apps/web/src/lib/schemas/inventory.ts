import {
	array,
	boolean,
	type InferOutput,
	literal,
	null_,
	nullable,
	maxLength,
	maxValue,
	minLength,
	minValue,
	nonEmpty,
	number,
	object,
	optional,
	parseJson,
	parse as vParse,
	pipe,
	record,
	string,
	union,
} from "valibot";
import type {
	InventoryAttributeDefinition,
	InventoryAttributes,
} from "$lib/types";

export const containerSchema = object({
	name: pipe(
		string(),
		minLength(1, "Name is required"),
		maxLength(100, "Name must be less than 100 characters"),
	),
	description: optional(
		pipe(
			string(),
			maxLength(500, "Description must be less than 500 characters"),
		),
	),
	parent_container_id: optional(string()),
});

export const attributeTypeSchema = union([
	literal("text"),
	literal("select"),
	literal("number"),
	literal("boolean"),
]);

export const inventoryAttributeValueSchema = union([
	string(),
	number(),
	boolean(),
	null_(),
]);

export const inventoryAttributesSchema = record(
	string(),
	inventoryAttributeValueSchema,
);

export const attributeDefinitionSchema = object({
	type: attributeTypeSchema,
	label: pipe(string(), minLength(1, "Label is required")),
	required: optional(boolean(), false),
	options: optional(array(string())), // For select type
	default_value: optional(inventoryAttributeValueSchema),
	name: optional(string()),
});

const serializedAttributeDefinitionsSchema = pipe(
	string(),
	parseJson(),
	array(attributeDefinitionSchema),
);

const serializedInventoryAttributesSchema = pipe(
	string(),
	parseJson(),
	inventoryAttributesSchema,
);

export const categorySchema = object({
	name: pipe(
		string(),
		minLength(1, "Name is required"),
		maxLength(50, "Name must be less than 50 characters"),
	),
	description: optional(
		pipe(
			string(),
			maxLength(500, "Description must be less than 500 characters"),
		),
	),
	available_attributes: optional(serializedAttributeDefinitionsSchema, "[]"),
});

export const itemSchema = object({
	container_id: pipe(
		string("Container is required"),
		nonEmpty("You must select a container"),
	),
	category_id: pipe(
		string("Category is required"),
		nonEmpty("You must select a category"),
	),
	attributes: optional(serializedInventoryAttributesSchema, "{}"),
	quantity: pipe(number(), minValue(1, "Quantity must be at least 1")),
	notes: optional(
		pipe(string(), maxLength(1000, "Notes must be less than 1000 characters")),
	),
	out_for_maintenance: optional(boolean(), false),
});

export const itemSearchSchema = object({
	search: optional(string()),
	category_id: optional(string()),
	container_id: optional(string()),
	out_for_maintenance: optional(boolean()),
	page: optional(pipe(number(), minValue(1))),
	limit: optional(pipe(number(), minValue(1), maxValue(100))),
});

export type ContainerSchema = InferOutput<typeof containerSchema>;
export type CategorySchema = InferOutput<typeof categorySchema>;
export type ItemSchema = InferOutput<typeof itemSchema>;
export type ItemSearchSchema = InferOutput<typeof itemSearchSchema>;
export type AttributeDefinition = InferOutput<typeof attributeDefinitionSchema>;

const apiAttributeDefinitionSchema = object({
	type: attributeTypeSchema,
	label: string(),
	required: optional(boolean(), false),
	options: optional(array(string())),
	defaultValue: optional(inventoryAttributeValueSchema),
	name: string(),
});

const apiAttributeDefinitionsSchema = array(apiAttributeDefinitionSchema);
const apiCategorySchema = object({
	id: string(),
	name: string(),
	description: optional(nullable(string())),
	availableAttributes: optional(apiAttributeDefinitionsSchema, []),
});

export function parseApiAttributeDefinitions(
	cause: unknown,
): InventoryAttributeDefinition[] {
	return vParse(apiAttributeDefinitionsSchema, cause).map((attribute) => ({
		type: attribute.type,
		label: attribute.label,
		name: attribute.name,
		required: attribute.required,
		options: attribute.options,
		default_value: attribute.defaultValue,
	}));
}

export function parseInventoryAttributes(cause: unknown): InventoryAttributes {
	return vParse(inventoryAttributesSchema, cause);
}

export function parseLegacyInventoryCategory(cause: unknown) {
	const category = vParse(apiCategorySchema, cause);
	return {
		id: category.id,
		name: category.name,
		description: category.description ?? null,
		available_attributes: parseApiAttributeDefinitions(
			category.availableAttributes,
		),
	};
}
