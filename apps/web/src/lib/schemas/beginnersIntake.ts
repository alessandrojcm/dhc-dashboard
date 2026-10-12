/**
 * ALE-381: the public Intake page's Pay form. It carries only the Intake
 * link token (the capability); Phoenix decides everything else.
 */
import * as v from "valibot";
import { requiredText } from "#lib/schemas/fields.js";

export const intakePaymentSchema = v.object({
	token: v.pipe(
		requiredText("This link is no longer active."),
		v.maxLength(128, "This link is no longer active."),
	),
});

export type IntakePaymentInput = v.InferInput<typeof intakePaymentSchema>;
