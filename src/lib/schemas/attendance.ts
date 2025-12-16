import * as v from "valibot";

export const AttendanceUpdateSchema = v.object({
	registration_id: v.pipe(v.string(), v.uuid("Must be a valid UUID")),
	attendance_status: v.picklist(["attended", "no_show", "excused"]),
	notes: v.optional(
		v.pipe(
			v.string(),
			v.maxLength(500, "Notes must be less than 500 characters"),
		),
	),
});

export const UpdateAttendanceSchema = v.object({
	attendance_updates: v.pipe(
		v.array(AttendanceUpdateSchema),
		v.minLength(1, "At least one attendance update required"),
	),
});

export type AttendanceUpdateInput = v.InferInput<typeof AttendanceUpdateSchema>;
export type UpdateAttendanceInput = v.InferInput<typeof UpdateAttendanceSchema>;
