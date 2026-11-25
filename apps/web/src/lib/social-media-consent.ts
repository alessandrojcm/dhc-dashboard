import type { SocialMediaConsent } from "@dhc/api-client";

const labels = {
	no: "No consent",
	yes_recognizable: "Yes, recognizable",
	yes_unrecognizable: "Yes, unrecognizable",
} satisfies Record<SocialMediaConsent, string>;

/** A person's social media consent as staff read it. */
export function formatSocialMediaConsent(consent: SocialMediaConsent): string {
	return labels[consent];
}
