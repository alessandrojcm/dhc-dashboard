/**
 * ALE-419: the Discord Doctor's kick review — the one place the page decides
 * what a kick dialog offers, previews and sends.
 *
 * Phoenix decides. Each report row carries `kick` (`bulk` | `single` |
 * `none`) and, when `none`, a staff-facing `kickRefusal`, from the same rule
 * the kick operation enforces; `kickReasons` is the audit-reason prefix
 * Phoenix will write for the signed-in administrator. This controller only
 * selects from those answers: it never restates the eligibility rule, never
 * builds the administrator's name, and shows the reason Phoenix actually
 * wrote (`auditReason`) once a kick returns. Phoenix re-decides every target
 * when the request arrives.
 */
import {
	discordDoctorKickMutation,
	type DiscordDoctorKickRequest,
	type DiscordDoctorKickResponse,
	type DiscordDoctorKickResult,
	type DiscordDoctorReport,
	type DiscordDoctorServerMember,
	type DiscordDoctorServerMembers,
} from "@dhc/api-client";
import {
	createMutation,
	useQueryClient,
	type QueryClient,
} from "@tanstack/svelte-query";
import { toast } from "svelte-sonner";
import { apiProblem } from "#lib/api-error.js";

export type ServerBucket = keyof DiscordDoctorServerMembers;
type KickableBucket = keyof DiscordDoctorReport["kickReasons"];

export type KickSkip = { row: DiscordDoctorServerMember; reason: string };

export type KickReviewState = {
	bucket: KickableBucket;
	targets: DiscordDoctorServerMember[];
	skipped: KickSkip[];
};

export type KickReviewNotify = {
	success(message: string): void;
	error(message: string): void;
};

/** Each request defaults to the generated `@dhc/api-client` call. */
export type KickReviewDeps = {
	queryClient?: QueryClient;
	kick?: (body: DiscordDoctorKickRequest) => Promise<DiscordDoctorKickResponse>;
	notify?: KickReviewNotify;
	/** Called after a kick request returns, e.g. to refetch the report. */
	onKicked?: () => void;
};

const BULK_LABELS = {
	linkedActive: null,
	linkedInactive: "Kick all inactive",
	pendingLink: null,
	unrecognized: "Kick all unrecognized",
} satisfies Record<ServerBucket, string | null>;

// A row Phoenix allows only as the one target of a request, met in a bulk
// review. Phoenix would refuse it with its own reason; say so up front.
const ONLY_ON_ITS_OWN = "Can only be kicked on its own";

function isKickable(bucket: ServerBucket): bucket is KickableBucket {
	return bucket !== "linkedActive";
}

export function createKickReview(
	report: () => DiscordDoctorReport | undefined,
	deps: KickReviewDeps = {},
) {
	const queryClient = deps.queryClient ?? useQueryClient();
	const notify = deps.notify ?? toast;

	let open = $state(false);
	let review = $state<KickReviewState | null>(null);
	let note = $state("");
	let results = $state<Record<string, DiscordDoctorKickResult>>({});
	let latestRows = $state<DiscordDoctorServerMember[]>([]);

	const injectedKick = deps.kick;
	const kick = createMutation(
		() => ({
			...discordDoctorKickMutation(),
			...(injectedKick && {
				mutationFn: (options: { body: DiscordDoctorKickRequest }) =>
					injectedKick(options.body),
			}),
		}),
		() => queryClient,
	);

	function canKick(row: DiscordDoctorServerMember): boolean {
		return row.kick !== "none";
	}

	function bulkLabel(bucket: ServerBucket): string | null {
		const label = BULK_LABELS[bucket];
		const rows = report()?.serverMembers[bucket] ?? [];
		return label && rows.some((row) => row.kick === "bulk") ? label : null;
	}

	function begin(next: KickReviewState) {
		review = next;
		note = "";
		open = true;
	}

	function startSingle(bucket: ServerBucket, row: DiscordDoctorServerMember) {
		if (!isKickable(bucket) || !canKick(row)) return;
		begin({ bucket, targets: [row], skipped: [] });
	}

	function startBulk(bucket: ServerBucket) {
		if (!isKickable(bucket) || !bulkLabel(bucket)) return;
		const rows = report()?.serverMembers[bucket] ?? [];
		begin({
			bucket,
			targets: rows.filter((row) => row.kick === "bulk"),
			skipped: rows
				.filter((row) => row.kick !== "bulk")
				.map((row) => ({ row, reason: row.kickRefusal ?? ONLY_ON_ITS_OWN })),
		});
	}

	function setOpen(next: boolean) {
		if (!next && kick.isPending) return;
		open = next;
		if (!next) {
			review = null;
			note = "";
		}
	}

	async function submit() {
		const current = review;
		if (!current || current.targets.length === 0) return;
		const trimmed = note.trim();
		const body: DiscordDoctorKickRequest = {
			discordUserIds: current.targets.map((row) => row.discordUserId),
			...(trimmed && { note: trimmed }),
		};
		try {
			const response = await kick.mutateAsync({ body });
			const next = { ...results };
			for (const result of response.data.results) {
				next[result.discordUserId] = result;
			}
			results = next;
			latestRows = current.targets;
			open = false;
			review = null;
			note = "";
			notify.success("Kick request completed");
			deps.onKicked?.();
		} catch (error) {
			notify.error(
				apiProblem(error)?.detail ?? "Failed to kick server accounts",
			);
		}
	}

	return {
		canKick,
		bulkLabel,
		startSingle,
		startBulk,
		setOpen,
		submit,
		get open() {
			return open;
		},
		get review(): KickReviewState | null {
			return review;
		},
		get note() {
			return note;
		},
		set note(value: string) {
			note = value;
		},
		/** The audit reason Phoenix will write: its prefix, then ` — <note>`. */
		get preview(): string {
			const prefix = review ? report()?.kickReasons[review.bucket] : undefined;
			if (!prefix) return "";
			const trimmed = note.trim();
			return trimmed ? `${prefix} — ${trimmed}` : prefix;
		},
		get pending() {
			return kick.isPending;
		},
		/** Latest outcome per Discord user id, with the reason Phoenix wrote. */
		get results(): Record<string, DiscordDoctorKickResult> {
			return results;
		},
		/** The accounts of the most recent kick request. */
		get latestRows(): DiscordDoctorServerMember[] {
			return latestRows;
		},
	};
}

export type KickReview = ReturnType<typeof createKickReview>;
