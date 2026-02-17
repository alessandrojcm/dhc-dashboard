import * as v from "valibot";

const inviteValidationSchema = v.object({
	dateOfBirth: v.pipe(v.string(), v.nonEmpty("Date of birth is required.")),
	email: v.pipe(v.string(), v.email()),
});

export { inviteValidationSchema };
