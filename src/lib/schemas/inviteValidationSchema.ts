import * as v from "valibot";

const inviteValidationSchema = v.object({
	dateOfBirth: v.pipe(v.string(), v.isoDate()),
	email: v.pipe(v.string(), v.email()),
});

export { inviteValidationSchema };
