import { form } from "$app/server";
import { invalid } from "@sveltejs/kit";
import * as v from "valibot";
import beginnersWaitlist, {
	beginnersWaitlistClientSchema,
} from "$lib/schemas/beginnersWaitlist";
import { waitlistCreateEntry } from "@dhc/api-client";
import { apiBaseUrl } from "$lib/server/api-client";
import { apiErrorDetail } from "$lib/server/api-error";

/**
 * Waitlist submission form
 * Uses the simplified client schema for type inference, but validates with the full
 * complex schema on the server to ensure all cross-field validation and transformations are applied.
 */
export const submitWaitlist = form(
	beginnersWaitlistClientSchema,
	async (data, issue) => {
		// Transform client data (string dateOfBirth) to server types (Date) for complex schema validation
		const transformedData = {
			...data,
			dateOfBirth: new Date(data.dateOfBirth),
		};

		// Validate with the full complex schema (includes cross-field validation and transformations)
		const result = v.safeParse(beginnersWaitlist, transformedData);

		if (!result.success) {
			const formIssues = result.issues.map((validationIssue) => {
				const fieldPath =
					validationIssue.path?.map((p) => p.key).join(".") || "";
				switch (fieldPath) {
					case "firstName":
						return issue.firstName(validationIssue.message);
					case "lastName":
						return issue.lastName(validationIssue.message);
					case "email":
						return issue.email(validationIssue.message);
					case "phoneNumber":
						return issue.phoneNumber(validationIssue.message);
					case "dateOfBirth":
						return issue.dateOfBirth(validationIssue.message);
					case "medicalConditions":
						return issue.medicalConditions(validationIssue.message);
					case "pronouns":
						return issue.pronouns(validationIssue.message);
					case "gender":
						return issue.gender(validationIssue.message);
					case "socialMediaConsent":
						return issue.socialMediaConsent(validationIssue.message);
					case "guardianFirstName":
						return issue.guardianFirstName(validationIssue.message);
					case "guardianLastName":
						return issue.guardianLastName(validationIssue.message);
					case "guardianPhoneNumber":
						return issue.guardianPhoneNumber(validationIssue.message);
					default:
						return validationIssue.message;
				}
			});

			invalid(...formIssues);
		}

		try {
			const { error } = await waitlistCreateEntry({
				baseUrl: apiBaseUrl(),
				body: {
					...result.output,
					dateOfBirth: result.output.dateOfBirth.toISOString().slice(0, 10),
				},
			});

			if (error) {
				const detail = apiErrorDetail(error);

				if (detail?.includes("already on the waitlist")) {
					invalid(issue.email("This email is already on the waitlist"));
				}

				throw new Error(detail ?? "Waitlist submission failed");
			}
		} catch (err) {
			console.error("Waitlist submission error:", err);

			if (err instanceof Error && err.message.includes("duplicate")) {
				invalid(issue.email("This email is already on the waitlist"));
			}

			throw new Error("Something went wrong, please try again later.");
		}

		return {
			success:
				"You have been added to the waitlist, we will be in contact soon!",
		};
	},
);
