import { form } from "$app/server";
import { invalid } from "@sveltejs/kit";
import * as v from "valibot";
import beginnersWaitlist, {
	beginnersWaitlistClientSchema,
} from "$lib/schemas/beginnersWaitlist";
import { waitlistCreateEntry } from "@dhc/api-client";
import { apiBaseUrl } from "$lib/server/api-client";

function apiErrorDetail(error: unknown): string | undefined {
	if (error && typeof error === "object" && "errors" in error) {
		const errors = error.errors;
		if (errors && typeof errors === "object" && "detail" in errors) {
			return typeof errors.detail === "string" ? errors.detail : undefined;
		}
	}
}

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
			// Map Valibot validation errors to form field issues
			for (const validationIssue of result.issues) {
				const fieldPath =
					validationIssue.path?.map((p) => p.key).join(".") || "";
				if (fieldPath) {
					// Create field-specific issue using dynamic property access
					// eslint-disable-next-line @typescript-eslint/no-explicit-any
					const issueProxy = issue as any;
					if (typeof issueProxy[fieldPath] === "function") {
						invalid(issueProxy[fieldPath](validationIssue.message));
					}
				} else {
					// Form-level error
					invalid(validationIssue.message);
				}
			}
			return;
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
