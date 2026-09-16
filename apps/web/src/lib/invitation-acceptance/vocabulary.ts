import * as v from "valibot";

/**
 * The frontend vocabulary for one browser's Invitation Acceptance session.
 *
 * Phoenix (`Dhc.Onboarding.Acceptance.View`) is the only durable authority;
 * this module only names its safe-view discriminator once so that route
 * decisions, remote commands, and UI presentation cannot each interpret it
 * differently. Phoenix spells two statuses in two ways (`awaiting_oauth` /
 * `awaitingDiscord`, `restart_verification` / `restartVerification`);
 * `normalizeAcceptanceView` collapses both onto the canonical name.
 */
export const invitationAcceptanceStatuses = [
	"awaitingDiscord",
	"discordVerified",
	"discordCollision",
	"discordUnavailable",
	"paymentReady",
	"paymentPending",
	"paymentNeedsAction",
	"paymentTerminal",
	"accepted",
	"restartVerification",
] as const;

export type InvitationAcceptanceStatus =
	(typeof invitationAcceptanceStatuses)[number];

export type AcceptanceDiscordPresentation = {
	username?: string;
	avatarUrl?: string;
};

/** Closed safe view; `state` is the discriminator (mirrors the Phoenix contract). */
export type AcceptanceView = {
	state: InvitationAcceptanceStatus;
	invitationEmail?: string;
	discord?: AcceptanceDiscordPresentation;
	discordVerified?: boolean;
	retryAllowed?: boolean;
	expiresAt?: string;
	complimentary?: boolean;
};

/**
 * Parses any Phoenix spelling of a status onto the canonical vocabulary and
 * rejects unknown strings, so a new Phoenix status is noticed rather than
 * rendered as step 1.
 */
export const acceptanceStatusSchema = v.union([
	v.picklist(invitationAcceptanceStatuses),
	v.pipe(
		v.literal("awaiting_oauth"),
		v.transform(() => "awaitingDiscord" as const),
	),
	v.pipe(
		v.literal("restart_verification"),
		v.transform(() => "restartVerification" as const),
	),
]);

const acceptanceViewSchema = v.object({
	state: acceptanceStatusSchema,
	invitationEmail: v.optional(v.string()),
	discord: v.optional(
		v.object({
			username: v.optional(v.string()),
			avatarUrl: v.optional(v.string()),
		}),
	),
	discordVerified: v.optional(v.boolean()),
	retryAllowed: v.optional(v.boolean()),
	expiresAt: v.optional(v.string()),
	complimentary: v.optional(v.boolean()),
});

/**
 * Phoenix wraps every safe view as `{ data: view }`. Parse untrusted bodies
 * with this schema at the API adapter; its output is an `AcceptanceView`.
 */
export const acceptanceStateResponseSchema = v.object({
	data: acceptanceViewSchema,
});

export function normalizeAcceptanceStatus(
	raw: string,
): InvitationAcceptanceStatus | undefined {
	const parsed = v.safeParse(acceptanceStatusSchema, raw);
	return parsed.success ? parsed.output : undefined;
}

/**
 * Typed result of one Phoenix acceptance operation, as seen by the workflow.
 * Transport details (ky, headers, parsing) stay in the API adapter.
 */
export type AcceptanceApiResult =
	| { kind: "view"; httpStatus: number; view: AcceptanceView }
	| { kind: "rejected"; httpStatus: number; detail?: string }
	| { kind: "unavailable"; reason: "timeout" | "network"; detail?: string };
