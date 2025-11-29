import * as Sentry from "@sentry/sveltekit";
import dayjs from "dayjs";
import {
	formatIncompletePhoneNumber,
	parsePhoneNumber,
} from "libphonenumber-js/min";
import * as v from "valibot";

export const phoneNumberValidator = (
	nomEmptyMessage: string = "Phone number is required.",
) =>
	v.pipe(
		v.string(),
		v.nonEmpty(nomEmptyMessage),
		v.check((input) => {
			if (input === "") return false;
			try {
				return Boolean(parsePhoneNumber(input ?? "", "IE")?.isValid());
			} catch (error) {
				Sentry.captureMessage(
					`Phone number validation error: ${error}`,
					"warning",
				);
				return false;
			}
		}, "Invalid phone number"),
		v.transform((input) => formatIncompletePhoneNumber(input)),
	);

export const dobValidator = v.pipe(
	v.date("Date of birth is required."),
	v.check(
		(input) => dayjs().diff(input, "years") >= 16,
		"You must be at least 16 years old.",
	),
);
