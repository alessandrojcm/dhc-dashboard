import * as v from "valibot";

/**
 * Coerces string "true"/"false" to boolean for hidden input fields.
 * Hidden inputs send string values, so we need to transform them.
 */
const booleanFromString = v.pipe(
	v.union([v.boolean(), v.literal("true"), v.literal("false"), v.undefined()]),
	v.transform((val) => val === true || val === "true"),
);

/**
 * Remote schema for create - dates as ISO strings for serialization.
 * Remote Functions serialize data, so we can't pass Date objects directly.
 */
export const CreateWorkshopRemoteSchema = v.object({
	title: v.pipe(
		v.string(),
		v.minLength(1, "Title is required"),
		v.maxLength(255),
	),
	description: v.optional(v.string(), ""),
	location: v.pipe(v.string(), v.minLength(1, "Location is required")),
	workshop_date: v.pipe(v.string(), v.nonEmpty("Workshop date is required")),
	workshop_end_date: v.pipe(
		v.string(),
		v.nonEmpty("Workshop end date is required"),
	),
	max_capacity: v.pipe(
		v.number(),
		v.minValue(1, "Capacity must be at least 1"),
	),
	price_member: v.pipe(v.number(), v.minValue(0, "Price cannot be negative")),
	price_non_member: v.optional(
		v.pipe(v.number(), v.minValue(0, "Price cannot be negative")),
	),
	is_public: v.optional(booleanFromString, false),
	refund_deadline_days: v.optional(
		v.pipe(v.number(), v.minValue(0, "Refund deadline cannot be negative")),
	),
	announce_discord: v.optional(booleanFromString, false),
	announce_email: v.optional(booleanFromString, false),
});

/**
 * Remote schema for update - all fields optional, dates as strings.
 */
export const UpdateWorkshopRemoteSchema = v.partial(CreateWorkshopRemoteSchema);

export type CreateWorkshopRemoteInput = v.InferInput<
	typeof CreateWorkshopRemoteSchema
>;
export type UpdateWorkshopRemoteInput = v.InferInput<
	typeof UpdateWorkshopRemoteSchema
>;
