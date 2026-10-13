import type {
	DiscordDoctorKickRequest,
	DiscordDoctorKickResponse,
	DiscordDoctorReport,
	DiscordDoctorServerMember,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createKickReview, type KickReviewDeps } from "./kick-review.svelte.js";

function account(
	id: string,
	overrides: Partial<DiscordDoctorServerMember> = {},
): DiscordDoctorServerMember {
	return {
		discordUserId: id,
		username: id,
		displayName: id,
		avatar: null,
		joinedAt: null,
		member: null,
		membershipStatus: null,
		protected: false,
		kick: "bulk",
		kickRefusal: null,
		...overrides,
	};
}

const report: DiscordDoctorReport = {
	serverMembers: {
		linkedActive: [
			account("active", {
				kick: "none",
				kickRefusal: "Active member",
			}),
		],
		linkedInactive: [
			account("sean"),
			account("ciaran", {
				protected: true,
				kick: "none",
				kickRefusal: "Protected member",
			}),
		],
		pendingLink: [account("fionnuala", { kick: "single" })],
		unrecognized: [account("unknown")],
	},
	missingMembers: [],
	cache: { fetchedAt: "2026-10-12T10:00:00Z", ttlSeconds: 60 },
	kickReasons: {
		linkedInactive: "DHC Doctor — Aoife Byrne: Linked – inactive",
		pendingLink: "DHC Doctor — Aoife Byrne: Pending link",
		unrecognized: "DHC Doctor — Aoife Byrne: Unrecognized",
	},
};

const cleanups: Array<() => void> = [];

afterEach(() => {
	while (cleanups.length) cleanups.pop()?.();
});

function setup(deps: KickReviewDeps = {}) {
	const queryClient = new QueryClient({
		defaultOptions: { mutations: { retry: false } },
	});
	const notify = { success: vi.fn(), error: vi.fn() };
	const onKicked = vi.fn();

	let review!: ReturnType<typeof createKickReview>;
	cleanups.push(
		$effect.root(() => {
			review = createKickReview(() => report, {
				queryClient,
				notify,
				onKicked,
				...deps,
			});
		}),
	);
	return { review, notify, onKicked };
}

function kicked(
	body: DiscordDoctorKickRequest,
	auditReason: string,
): DiscordDoctorKickResponse {
	return {
		data: {
			results: body.discordUserIds.map((discordUserId) => ({
				discordUserId,
				outcome: "kicked",
				reason: null,
				error: null,
				auditReason,
			})),
		},
	};
}

describe("createKickReview (ALE-419)", () => {
	it("offers each kick Phoenix allows and a bulk kick only where Phoenix allows one", () => {
		const { review } = setup();

		expect(review.canKick(report.serverMembers.linkedInactive[0])).toBe(true);
		expect(review.canKick(report.serverMembers.linkedInactive[1])).toBe(false);
		expect(review.canKick(report.serverMembers.pendingLink[0])).toBe(true);
		expect(review.bulkLabel("linkedInactive")).toBe("Kick all inactive");
		expect(review.bulkLabel("unrecognized")).toBe("Kick all unrecognized");
		expect(review.bulkLabel("pendingLink")).toBeNull();
		expect(review.bulkLabel("linkedActive")).toBeNull();
	});

	it("reviews a bulk kick: Phoenix's bulk rows as targets, the rest skipped with Phoenix's reason", () => {
		const { review } = setup();

		review.startBulk("linkedInactive");

		expect(review.open).toBe(true);
		expect(review.review?.targets.map((row) => row.discordUserId)).toEqual([
			"sean",
		]);
		expect(
			review.review?.skipped.map(({ row, reason }) => [
				row.discordUserId,
				reason,
			]),
		).toEqual([["ciaran", "Protected member"]]);
	});

	it("refuses to open a review Phoenix does not allow", () => {
		const { review } = setup();

		review.startBulk("pendingLink");
		review.startSingle("linkedActive", report.serverMembers.linkedActive[0]);

		expect(review.open).toBe(false);
		expect(review.review).toBeNull();
	});

	it("previews Phoenix's audit-reason prefix followed by the trimmed note", () => {
		const { review } = setup();
		review.startSingle("pendingLink", report.serverMembers.pendingLink[0]);

		expect(review.preview).toBe("DHC Doctor — Aoife Byrne: Pending link");
		review.note = "  Not a member  ";
		expect(review.preview).toBe(
			"DHC Doctor — Aoife Byrne: Pending link — Not a member",
		);
		review.note = "   ";
		expect(review.preview).toBe("DHC Doctor — Aoife Byrne: Pending link");
	});

	it("submits exactly the reviewed targets and keeps the reason Phoenix wrote", async () => {
		const kick = vi.fn(async (body: DiscordDoctorKickRequest) =>
			kicked(body, "DHC Doctor — Aoife Byrne: Linked – inactive — Left"),
		);
		const { review, notify, onKicked } = setup({ kick });
		review.startBulk("linkedInactive");
		review.note = " Left ";

		await review.submit();

		expect(kick).toHaveBeenCalledWith({
			discordUserIds: ["sean"],
			note: "Left",
		});
		expect(review.open).toBe(false);
		expect(review.review).toBeNull();
		expect(review.note).toBe("");
		expect(review.latestRows.map((row) => row.discordUserId)).toEqual(["sean"]);
		expect(review.results.sean).toMatchObject({
			outcome: "kicked",
			auditReason: "DHC Doctor — Aoife Byrne: Linked – inactive — Left",
		});
		expect(notify.success).toHaveBeenCalledWith("Kick request completed");
		expect(onKicked).toHaveBeenCalledOnce();
	});

	it("omits a blank note from the request", async () => {
		const kick = vi.fn(async (body: DiscordDoctorKickRequest) =>
			kicked(body, "DHC Doctor — Aoife Byrne: Unrecognized"),
		);
		const { review } = setup({ kick });
		review.startSingle("unrecognized", report.serverMembers.unrecognized[0]);
		review.note = "  ";

		await review.submit();

		expect(kick).toHaveBeenCalledWith({ discordUserIds: ["unknown"] });
	});

	it("keeps the review open and shows Phoenix's problem when the request fails", async () => {
		const kick = vi.fn(async () => {
			throw {
				errors: { detail: "Authenticated administrator profile unavailable" },
			};
		});
		const { review, notify, onKicked } = setup({ kick });
		review.startBulk("unrecognized");

		await review.submit();

		expect(notify.error).toHaveBeenCalledWith(
			"Authenticated administrator profile unavailable",
		);
		expect(review.open).toBe(true);
		expect(review.review?.targets).toHaveLength(1);
		expect(onKicked).not.toHaveBeenCalled();
	});

	it("closing the review clears it and the note", () => {
		const { review } = setup();
		review.startBulk("unrecognized");
		review.note = "draft";

		review.setOpen(false);

		expect(review.open).toBe(false);
		expect(review.review).toBeNull();
		expect(review.note).toBe("");
	});
});
