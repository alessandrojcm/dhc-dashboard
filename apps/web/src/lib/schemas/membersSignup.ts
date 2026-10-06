import * as v from "valibot";
import { phoneNumber } from "#lib/schemas/fields.js";

export const memberSignupSchema = v.object({
	nextOfKin: v.pipe(v.string(), v.nonEmpty("Please enter your next of kin.")),
	nextOfKinNumber: phoneNumber("Phone number of your next of kin is required."),
	insuranceFormSubmitted: v.optional(v.boolean()),
	stripeConfirmationToken: v.string(),
	couponCode: v.optional(v.string()),
});
