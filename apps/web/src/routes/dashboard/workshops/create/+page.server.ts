import { authorize } from "$lib/server/auth";
import { WORKSHOP_ROLES } from "$lib/server/roles";
import { coerceToCreateWorkshopSchema } from "$lib/server/workshop-generator";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, url }) => {
	await authorize(locals, WORKSHOP_ROLES);

	// Check if this is a generated workshop (from quick create)
	const generatedParam = url.searchParams.get("generated");
	let initialData:
		| {
				title: string;
				description: string;
				location: string;
				workshop_date: Date;
				workshop_end_date: Date;
				max_capacity: number;
				price_member: number;
				price_non_member: number | undefined;
				is_public: boolean;
				refund_deadline_days: number | null;
				announce_discord: boolean;
				announce_email: boolean;
		  }
		| undefined = undefined;

	if (generatedParam && generatedParam !== "true") {
		try {
			const result = coerceToCreateWorkshopSchema(
				JSON.parse(decodeURIComponent(generatedParam)),
			);
			if (result.success && result.output) {
				const parsed = result.output;
				initialData = {
					title: parsed.title,
					description: parsed.description,
					location: parsed.location,
					workshop_date: parsed.workshop_date,
					workshop_end_date: parsed.workshop_end_date,
					max_capacity: parsed.max_capacity,
					price_member: parsed.price_member,
					price_non_member: parsed.price_non_member,
					is_public: parsed.is_public,
					refund_deadline_days: parsed.refund_deadline_days,
					announce_discord: parsed.announce_discord,
					announce_email: parsed.announce_email,
				};
			}
		} catch (error) {
			console.error("Failed to parse generated data:", error);
		}
	}

	return {
		initialData,
		isGenerated: !!initialData,
	};
};
