import type {
	TrainingAnnouncement,
	TrainingAnnouncementCopyRequest,
	TrainingAnnouncementCreateRequest,
	TrainingAnnouncementScheduleRequest,
	TrainingAnnouncementWarning,
} from "@dhc/api-client";
import { assign, fromPromise, setup, type SnapshotFrom } from "xstate";
import { apiProblem, type ApiFieldMessages } from "#lib/api-error.js";
import {
	copyRequest,
	createRequest,
	scheduleChanged,
	scheduleRequest,
	type AnnouncementDraft,
	type AnnouncementSave,
} from "./announcement";

/**
 * Component-scoped save protocol of the Training Announcement sheet (ALE-448).
 *
 * Creating is one write. Editing is two separate, non-atomic writes the API
 * models apart: the schedule (only when it actually changed, since it swaps
 * the pending job and may return advisory warnings), then the copy. Their
 * order is the safety rule — an elapsed slot is refused before any copy is
 * written, so a schedule refusal never reaches the copy stage.
 *
 * A copy failure after a schedule write lands in `edit.copyFailed`: the
 * schedule stays applied (nothing is rolled back) and `baseline` is the row
 * Phoenix returned for it, so the next save re-runs the schedule stage only if
 * the draft's schedule differs from what already landed.
 *
 * TanStack Query stays the server-state owner: the injected actors are its
 * mutations, which own optimistic rows, rollback and list invalidation. The
 * machine never caches a row for display. Instantiate it per sheet with
 * `useMachine`; stopping it (closing the sheet) discards late results.
 */

export type AnnouncementSaveStage = "create" | "schedule" | "copy";

/** Why the last save stopped, scoped to the request that refused it. */
export type AnnouncementSaveProblem = {
	stage: AnnouncementSaveStage;
	/** Phoenix's problem detail, or `undefined` when the failure had none. */
	detail: string | undefined;
	fields: ApiFieldMessages[];
};

export type AnnouncementSaveInput = {
	/** `null` creates a new announcement; an existing row edits it. */
	announcement: TrainingAnnouncement | null;
};

export type AnnouncementSaveContext = {
	/**
	 * The authoritative row the next save compares its draft against: the row
	 * the sheet opened, then the row a successful schedule write returned.
	 */
	baseline: TrainingAnnouncement | null;
	/** The draft being saved, as it was when the save started. */
	draft: AnnouncementDraft | null;
	/** Warnings from the schedule write this sheet already committed. */
	warnings: TrainingAnnouncementWarning[];
	/**
	 * A schedule write committed in this sheet. It is never rolled back, so a
	 * later copy failure leaves the announcement half-edited, honestly.
	 */
	scheduleApplied: boolean;
	problem: AnnouncementSaveProblem | null;
};

export type AnnouncementSaveEvent =
	| { type: "SAVE"; draft: AnnouncementDraft }
	| { type: "CLOSE" };

/** Implementations a host component provides through `announcementSaveMachine.provide`. */
export type AnnouncementSaveImplementations = {
	create: (input: {
		body: TrainingAnnouncementCreateRequest;
	}) => Promise<AnnouncementSave>;
	updateSchedule: (input: {
		id: string;
		body: TrainingAnnouncementScheduleRequest;
	}) => Promise<AnnouncementSave>;
	updateCopy: (input: {
		id: string;
		body: TrainingAnnouncementCopyRequest;
	}) => Promise<TrainingAnnouncement>;
	/** A save committed: report it (warnings included) to the owner. */
	saved: (save: AnnouncementSave) => void;
	/** The workflow is over (saved or dismissed): close the sheet. */
	close: () => void;
};

function problemOf(
	cause: unknown,
	stage: AnnouncementSaveStage,
): AnnouncementSaveProblem {
	const problem = apiProblem(cause);
	return { stage, detail: problem?.detail, fields: problem?.fields ?? [] };
}

function unprovided(name: string) {
	return async (): Promise<never> => {
		throw new Error(`${name} must be provided by the host`);
	};
}

function requireBaseline(context: AnnouncementSaveContext) {
	if (!context.baseline || !context.draft)
		throw new Error("an edit stage needs the announcement and its draft");
	return { id: context.baseline.id, draft: context.draft };
}

/**
 * How every resting edit state routes a save: through the schedule stage only
 * when the draft moved off the authoritative schedule, otherwise straight to
 * the copy stage.
 */
const editSave = [
	{
		guard: "scheduleChanged",
		target: "savingSchedule",
		actions: "startSave",
	},
	{ target: "savingCopy", actions: "startSave" },
] as const;

export const announcementSaveMachine = setup({
	// SAFETY: XState's `setup({ types })` reads only the *types* of these
	// placeholders; the empty objects are never used as values.
	types: {
		context: {} as AnnouncementSaveContext,
		events: {} as AnnouncementSaveEvent,
		input: {} as AnnouncementSaveInput,
	},
	actors: {
		create: fromPromise<
			AnnouncementSave,
			{ body: TrainingAnnouncementCreateRequest }
		>(unprovided("create")),
		updateSchedule: fromPromise<
			AnnouncementSave,
			{ id: string; body: TrainingAnnouncementScheduleRequest }
		>(unprovided("updateSchedule")),
		updateCopy: fromPromise<
			TrainingAnnouncement,
			{ id: string; body: TrainingAnnouncementCopyRequest }
		>(unprovided("updateCopy")),
	},
	actions: {
		startSave: assign({
			draft: ({ event }) => (event.type === "SAVE" ? event.draft : null),
			problem: null,
		}),
		saved: (_, _save: AnnouncementSave) => {},
		close: () => {},
	},
	guards: {
		creating: ({ context }) => context.baseline === null,
		scheduleChanged: ({ context, event }) =>
			event.type === "SAVE" &&
			context.baseline !== null &&
			scheduleChanged(event.draft, context.baseline),
	},
}).createMachine({
	id: "announcementSave",
	context: ({ input }) => ({
		baseline: input.announcement,
		draft: null,
		warnings: [],
		scheduleApplied: false,
		problem: null,
	}),
	initial: "opening",
	on: {
		// Closing mid-save stops the in-flight invocation; its late result is
		// dropped. The write itself may still commit — the query client
		// reconciles the list either way.
		CLOSE: { target: ".closed" },
	},
	states: {
		opening: {
			always: [{ guard: "creating", target: "create" }, { target: "edit" }],
		},
		create: {
			initial: "drafting",
			states: {
				drafting: { on: { SAVE: { target: "saving", actions: "startSave" } } },
				saving: {
					tags: ["saving"],
					invoke: {
						src: "create",
						input: ({ context }) => {
							if (!context.draft) throw new Error("create needs a draft");
							return { body: createRequest(context.draft) };
						},
						onDone: {
							target: "#announcementSave.saved",
							actions: [{ type: "saved", params: ({ event }) => event.output }],
						},
						onError: {
							target: "failed",
							actions: assign({
								problem: ({ event }) => problemOf(event.error, "create"),
							}),
						},
					},
				},
				failed: { on: { SAVE: { target: "saving", actions: "startSave" } } },
			},
		},
		edit: {
			initial: "drafting",
			states: {
				drafting: {
					on: { SAVE: editSave },
				},
				savingSchedule: {
					tags: ["saving"],
					invoke: {
						src: "updateSchedule",
						input: ({ context }) => {
							const { id, draft } = requireBaseline(context);
							return { id, body: scheduleRequest(draft) };
						},
						onDone: {
							target: "savingCopy",
							actions: assign({
								baseline: ({ event }) => event.output.announcement,
								warnings: ({ event }) => event.output.warnings,
								scheduleApplied: true,
							}),
						},
						onError: {
							target: "scheduleFailed",
							actions: assign({
								problem: ({ event }) => problemOf(event.error, "schedule"),
							}),
						},
					},
				},
				savingCopy: {
					tags: ["saving"],
					invoke: {
						src: "updateCopy",
						input: ({ context }) => {
							const { id, draft } = requireBaseline(context);
							return { id, body: copyRequest(draft) };
						},
						onDone: {
							target: "#announcementSave.saved",
							actions: [
								{
									type: "saved",
									params: ({ context, event }) => ({
										announcement: event.output,
										warnings: context.warnings,
									}),
								},
							],
						},
						onError: {
							target: "copyFailed",
							actions: assign({
								problem: ({ event }) => problemOf(event.error, "copy"),
							}),
						},
					},
				},
				// Nothing was written; the next save starts from the opened row.
				scheduleFailed: {
					on: { SAVE: editSave },
				},
				// The schedule write (if any) committed and stays; only the copy
				// is missing. Retrying resumes at the copy stage unless the draft's
				// schedule changed again since that write.
				copyFailed: {
					on: { SAVE: editSave },
				},
			},
		},
		saved: { type: "final", entry: "close" },
		closed: { type: "final", entry: "close" },
	},
});

export type AnnouncementSaveSnapshot = SnapshotFrom<
	typeof announcementSaveMachine
>;
