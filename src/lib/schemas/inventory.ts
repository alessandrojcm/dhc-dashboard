import {
	object,
	string,
	optional,
	pipe,
	minLength,
	maxLength,
	number,
	minValue,
	maxValue,
	boolean,
	record,
	any,
	array,
	union,
	literal,
	nonEmpty,
	type InferOutput
} from 'valibot';

export const containerSchema = object({
	name: pipe(
		string(),
		minLength(1, 'Name is required'),
		maxLength(100, 'Name must be less than 100 characters')
	),
	description: optional(
		pipe(string(), maxLength(500, 'Description must be less than 500 characters'))
	),
	parent_container_id: optional(string())
});

export const attributeTypeSchema = union([
	literal('text'),
	literal('select'),
	literal('number'),
	literal('boolean')
]);

export const attributeDefinitionSchema = object({
	type: attributeTypeSchema,
	label: pipe(string(), minLength(1, 'Label is required')),
	required: optional(boolean()),
	options: optional(array(string())), // For select type
	default_value: optional(any()),
	name: optional(string())
});

export const categorySchema = object({
	name: pipe(
		string(),
		minLength(1, 'Name is required'),
		maxLength(50, 'Name must be less than 50 characters')
	),
	description: optional(
		pipe(string(), maxLength(500, 'Description must be less than 500 characters'))
	),
	available_attributes: optional(array(attributeDefinitionSchema), [])
});

export const itemSchema = object({
	container_id: pipe(string('Container is required'), nonEmpty('You must select a container')),
	category_id: pipe(string('Category is required'), nonEmpty('You must select a category')),
	attributes: optional(record(string(), any())),
	quantity: pipe(number(), minValue(1, 'Quantity must be at least 1')),
	notes: optional(pipe(string(), maxLength(1000, 'Notes must be less than 1000 characters'))),
	out_for_maintenance: optional(boolean())
});

export const itemSearchSchema = object({
	search: optional(string()),
	category_id: optional(string()),
	container_id: optional(string()),
	out_for_maintenance: optional(boolean()),
	page: optional(pipe(number(), minValue(1))),
	limit: optional(pipe(number(), minValue(1), maxValue(100)))
});

export type ContainerSchema = InferOutput<typeof containerSchema>;
export type CategorySchema = InferOutput<typeof categorySchema>;
export type ItemSchema = InferOutput<typeof itemSchema>;
export type ItemSearchSchema = InferOutput<typeof itemSearchSchema>;
export type AttributeDefinition = InferOutput<typeof attributeDefinitionSchema>;
