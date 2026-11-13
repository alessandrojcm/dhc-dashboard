import type { TrainingAnnouncement } from "@dhc/api-client";
import { describe, expect, it, vi } from "vitest";
import { createActor, fromPromise, waitFor } from "xstate";
import {
	announcementDraft,
	newAnnouncementDraft,
	type AnnouncementDraft,
	type AnnouncementSave,
} from "./announcement";
import {
	announcementSaveMachine,
	type AnnouncementSaveImplementations,
} from "./save-machine";

const TODAY = "2026-10-01"; // a Thursday
const ID = "11111111-1111-1111-1111-111111111111";

function row(
	overrides: Partial<TrainingAnnouncement> = {},
): TrainingAnnouncement {
	return {
		id: ID,
		kind: "roll_call",
		weekday: 4,
		oneOffDate: null,
		postTime: "10:00:00",
		title: "Roll call {{date}}",
		message: "Who is coming?",
		mentionEveryone: true,
		enabled: true,
		retired: false,
		firstAttemptedAt: null,
		createdAt: "2026-09-01T10:00:00Z",
		updatedAt: "2026-09-01T10:00:00Z",
		...overrides,
	};
}

type Deferred<T> = {
	promise: Promise<T>;
	resolve: (value: T) => void;
	reject: (cause: unknown) => void;
};

function deferred<T>(): Deferred<T> {
	let resolve!: (value: T) => void;
	let reject!: (cause: unknown) => void;
	const promise = new Promise<T>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

/** A Phoenix problem body as the generated client rejects with it. */
function problem(detail: string, fields: Record<string, string[]> = {}) {
	return { errors: { detail, fields } };
}

type Requests = Partial<
	Pick<
		AnnouncementSaveImplementations,
		"create" | "updateSchedule" | "updateCopy"
	>
>;

function harness(
	announcement: TrainingAnnouncement | null,
	requests: Requests = {},
) {
	const order: string[] = [];
	const create = vi.fn<AnnouncementSaveImplementations["create"]>(
		requests.create ??
			(async ({ body }) => ({
				announcement: row({ ...body, id: "new" }),
				warnings: ["slot_collision"],
			})),
	);
	const updateSchedule = vi.fn<
		AnnouncementSaveImplementations["updateSchedule"]
	>(
		requests.updateSchedule ??
			(async ({ body }) => ({
				announcement: row({ ...body, postTime: `${body.postTime}:00` }),
				warnings: ["exception_intersection_changed"],
			})),
	);
	const updateCopy = vi.fn<AnnouncementSaveImplementations["updateCopy"]>(
		requests.updateCopy ?? (async ({ body }) => row({ ...body })),
	);
	const saved = vi.fn<AnnouncementSaveImplementations["saved"]>();
	const close = vi.fn<AnnouncementSaveImplementations["close"]>();

	const actor = createActor(
		announcementSaveMachine.provide({
			actors: {
				create: fromPromise(({ input }) => {
					order.push("create");
					return create(input);
				}),
				updateSchedule: fromPromise(({ input }) => {
					order.push("schedule");
					return updateSchedule(input);
				}),
				updateCopy: fromPromise(({ input }) => {
					order.push("copy");
					return updateCopy(input);
				}),
			},
			actions: {
				saved: (_, save: AnnouncementSave) => saved(save),
				close: () => close(),
			},
		}),
		{ input: { announcement } },
	);
	actor.start();
	return { actor, order, create, updateSchedule, updateCopy, saved, close };
}

function editDraft(
	changes: Partial<AnnouncementDraft> = {},
): AnnouncementDraft {
	return { ...announcementDraft(row(), TODAY), ...changes };
}

describe("create path", () => {
	it("creates in one request, reports the warnings and closes", async () => {
		const h = harness(null);
		expect(h.actor.getSnapshot().matches({ create: "drafting" })).toBe(true);

		h.actor.send({ type: "SAVE", draft: newAnnouncementDraft(TODAY) });
		expect(h.actor.getSnapshot().hasTag("saving")).toBe(true);
		await waitFor(h.actor, (s) => s.status === "done");

		expect(h.order).toEqual(["create"]);
		expect(h.create).toHaveBeenCalledWith({
			body: expect.objectContaining({ kind: "roll_call", oneOffDate: null }),
		});
		expect(h.saved).toHaveBeenCalledWith({
			announcement: expect.objectContaining({ id: "new" }),
			warnings: ["slot_collision"],
		});
		expect(h.close).toHaveBeenCalledTimes(1);
		expect(h.saved.mock.invocationCallOrder[0]).toBeLessThan(
			h.close.mock.invocationCallOrder[0]!,
		);
	});

	it("a refusal stays open with the create-stage problem, and a retry creates again", async () => {
		const h = harness(null, {
			create: vi
				.fn<AnnouncementSaveImplementations["create"]>()
				.mockRejectedValueOnce(
					problem("postTime: elapsed", { postTime: ["elapsed"] }),
				)
				.mockImplementationOnce(async ({ body }) => ({
					announcement: row({ ...body, id: "new" }),
					warnings: [],
				})),
		});
		h.actor.send({ type: "SAVE", draft: newAnnouncementDraft(TODAY) });
		await waitFor(h.actor, (s) => s.matches({ create: "failed" }));
		expect(h.actor.getSnapshot().context.problem).toEqual({
			stage: "create",
			detail: "postTime: elapsed",
			fields: [{ field: "postTime", messages: ["elapsed"] }],
		});
		expect(h.close).not.toHaveBeenCalled();

		h.actor.send({ type: "SAVE", draft: newAnnouncementDraft(TODAY) });
		// The retry clears the previous stage's problem while it runs.
		expect(h.actor.getSnapshot().context.problem).toBeNull();
		await waitFor(h.actor, (s) => s.status === "done");
		expect(h.order).toEqual(["create", "create"]);
		expect(h.saved).toHaveBeenCalledTimes(1);
	});

	it("a failure without a problem body still lands in the failed state", async () => {
		const h = harness(null, {
			create: async () => {
				throw new TypeError("Failed to fetch");
			},
		});
		h.actor.send({ type: "SAVE", draft: newAnnouncementDraft(TODAY) });
		await waitFor(h.actor, (s) => s.matches({ create: "failed" }));
		expect(h.actor.getSnapshot().context.problem).toEqual({
			stage: "create",
			detail: undefined,
			fields: [],
		});
	});
});

describe("edit path", () => {
	it("a schedule change saves the schedule, then the copy, and carries the schedule warnings", async () => {
		const h = harness(row());
		h.actor.send({
			type: "SAVE",
			draft: editDraft({ postTime: "11:00", title: "New title" }),
		});
		expect(h.actor.getSnapshot().matches({ edit: "savingSchedule" })).toBe(
			true,
		);
		await waitFor(h.actor, (s) => s.status === "done");

		expect(h.order).toEqual(["schedule", "copy"]);
		expect(h.updateSchedule).toHaveBeenCalledWith({
			id: ID,
			body: { weekday: 4, oneOffDate: null, postTime: "11:00" },
		});
		expect(h.updateCopy).toHaveBeenCalledWith({
			id: ID,
			body: {
				title: "New title",
				message: "Who is coming?",
				mentionEveryone: true,
			},
		});
		expect(h.saved).toHaveBeenCalledWith({
			announcement: expect.objectContaining({ title: "New title" }),
			warnings: ["exception_intersection_changed"],
		});
		expect(h.close).toHaveBeenCalledTimes(1);
	});

	it("a copy-only edit issues only the copy request and carries no warnings", async () => {
		const h = harness(row());
		h.actor.send({ type: "SAVE", draft: editDraft({ message: "Changed" }) });
		expect(h.actor.getSnapshot().matches({ edit: "savingCopy" })).toBe(true);
		await waitFor(h.actor, (s) => s.status === "done");

		expect(h.order).toEqual(["copy"]);
		expect(h.saved).toHaveBeenCalledWith({
			announcement: expect.objectContaining({ message: "Changed" }),
			warnings: [],
		});
	});

	it("a schedule refusal never issues the copy write", async () => {
		const h = harness(row(), {
			updateSchedule: async () => {
				throw problem("postTime: the first send instant has elapsed", {
					postTime: ["the first send instant has elapsed"],
				});
			},
		});
		h.actor.send({ type: "SAVE", draft: editDraft({ postTime: "08:00" }) });
		await waitFor(h.actor, (s) => s.matches({ edit: "scheduleFailed" }));

		expect(h.order).toEqual(["schedule"]);
		expect(h.updateCopy).not.toHaveBeenCalled();
		const { context } = h.actor.getSnapshot();
		expect(context.problem).toMatchObject({
			stage: "schedule",
			fields: [
				{ field: "postTime", messages: ["the first send instant has elapsed"] },
			],
		});
		expect(context.scheduleApplied).toBe(false);
		expect(h.saved).not.toHaveBeenCalled();
		expect(h.close).not.toHaveBeenCalled();
	});

	it("after a schedule refusal, reverting the schedule saves only the copy", async () => {
		const h = harness(row(), {
			updateSchedule: async () => {
				throw problem("elapsed");
			},
		});
		h.actor.send({ type: "SAVE", draft: editDraft({ postTime: "08:00" }) });
		await waitFor(h.actor, (s) => s.matches({ edit: "scheduleFailed" }));

		h.actor.send({ type: "SAVE", draft: editDraft({ title: "Only copy" }) });
		await waitFor(h.actor, (s) => s.status === "done");
		expect(h.order).toEqual(["schedule", "copy"]);
		expect(h.saved).toHaveBeenCalledWith({
			announcement: expect.objectContaining({ title: "Only copy" }),
			warnings: [],
		});
	});

	it("a copy failure after a schedule write is its own honest, partial stage", async () => {
		const updateCopy = vi
			.fn<AnnouncementSaveImplementations["updateCopy"]>()
			.mockRejectedValueOnce(
				problem("message: unknown placeholder", {
					message: ["unknown placeholder"],
				}),
			)
			.mockImplementation(async ({ body }) =>
				row({ ...body, postTime: "11:00:00" }),
			);
		const h = harness(row(), { updateCopy });
		const draft = editDraft({ postTime: "11:00", message: "{{nope}}" });
		h.actor.send({ type: "SAVE", draft });
		await waitFor(h.actor, (s) => s.matches({ edit: "copyFailed" }));

		const { context } = h.actor.getSnapshot();
		expect(context.scheduleApplied).toBe(true);
		expect(context.problem).toMatchObject({
			stage: "copy",
			fields: [{ field: "message", messages: ["unknown placeholder"] }],
		});
		// The committed schedule is the new baseline; nothing is rolled back.
		expect(context.baseline?.postTime).toBe("11:00:00");
		expect(h.saved).not.toHaveBeenCalled();
		expect(h.close).not.toHaveBeenCalled();

		// Retrying resumes at the copy stage: the schedule already landed.
		h.actor.send({ type: "SAVE", draft: { ...draft, message: "Fixed" } });
		expect(h.actor.getSnapshot().matches({ edit: "savingCopy" })).toBe(true);
		await waitFor(h.actor, (s) => s.status === "done");
		expect(h.order).toEqual(["schedule", "copy", "copy"]);
		expect(h.updateSchedule).toHaveBeenCalledTimes(1);
		// The committed schedule's warnings still reach the owner.
		expect(h.saved).toHaveBeenCalledWith({
			announcement: expect.objectContaining({ message: "Fixed" }),
			warnings: ["exception_intersection_changed"],
		});
	});

	it("after a copy failure, a further schedule change runs the schedule stage again", async () => {
		const h = harness(row(), {
			updateCopy: vi
				.fn<AnnouncementSaveImplementations["updateCopy"]>()
				.mockRejectedValueOnce(problem("copy refused"))
				.mockImplementation(async ({ body }) => row({ ...body })),
		});
		h.actor.send({ type: "SAVE", draft: editDraft({ postTime: "11:00" }) });
		await waitFor(h.actor, (s) => s.matches({ edit: "copyFailed" }));

		h.actor.send({ type: "SAVE", draft: editDraft({ postTime: "12:00" }) });
		expect(h.actor.getSnapshot().matches({ edit: "savingSchedule" })).toBe(
			true,
		);
		await waitFor(h.actor, (s) => s.status === "done");
		expect(h.order).toEqual(["schedule", "copy", "schedule", "copy"]);
		expect(h.updateSchedule).toHaveBeenLastCalledWith({
			id: ID,
			body: { weekday: 4, oneOffDate: null, postTime: "12:00" },
		});
	});

	it("a copy-only failure is not reported as a partial schedule write", async () => {
		const h = harness(row(), {
			updateCopy: async () => {
				throw problem("copy refused");
			},
		});
		h.actor.send({ type: "SAVE", draft: editDraft({ title: "x" }) });
		await waitFor(h.actor, (s) => s.matches({ edit: "copyFailed" }));
		expect(h.actor.getSnapshot().context.scheduleApplied).toBe(false);
		expect(h.order).toEqual(["copy"]);
	});
});

describe("repeated events, stale results and teardown", () => {
	it("ignores a second save while a stage is in flight", async () => {
		const schedule = deferred<AnnouncementSave>();
		const h = harness(row(), { updateSchedule: () => schedule.promise });
		const draft = editDraft({ postTime: "11:00" });
		h.actor.send({ type: "SAVE", draft });
		h.actor.send({ type: "SAVE", draft });
		h.actor.send({ type: "SAVE", draft: editDraft({ title: "late" }) });
		expect(h.updateSchedule).toHaveBeenCalledTimes(1);

		schedule.resolve({
			announcement: row({ postTime: "11:00:00" }),
			warnings: [],
		});
		await waitFor(h.actor, (s) => s.status === "done");
		expect(h.order).toEqual(["schedule", "copy"]);
		// The copy stage writes the draft the save started with.
		expect(h.updateCopy).toHaveBeenCalledWith({
			id: ID,
			body: expect.objectContaining({ title: "Roll call {{date}}" }),
		});
	});

	it("closing mid-schedule discards the late result and never writes the copy", async () => {
		const schedule = deferred<AnnouncementSave>();
		const h = harness(row(), { updateSchedule: () => schedule.promise });
		h.actor.send({ type: "SAVE", draft: editDraft({ postTime: "11:00" }) });
		h.actor.send({ type: "CLOSE" });
		expect(h.actor.getSnapshot().status).toBe("done");
		expect(h.close).toHaveBeenCalledTimes(1);

		schedule.resolve({
			announcement: row(),
			warnings: ["exception_intersection_changed"],
		});
		await Promise.resolve();
		await Promise.resolve();
		expect(h.updateCopy).not.toHaveBeenCalled();
		expect(h.saved).not.toHaveBeenCalled();
		expect(h.close).toHaveBeenCalledTimes(1);
	});

	it("a create that answers after the actor stopped does not report or close", async () => {
		const created = deferred<AnnouncementSave>();
		const h = harness(null, { create: () => created.promise });
		h.actor.send({ type: "SAVE", draft: newAnnouncementDraft(TODAY) });
		// The sheet was destroyed (e.g. its owner unmounted it).
		h.actor.stop();

		created.resolve({ announcement: row(), warnings: [] });
		await Promise.resolve();
		await Promise.resolve();
		expect(h.saved).not.toHaveBeenCalled();
		expect(h.close).not.toHaveBeenCalled();
	});

	it("a refusal that arrives after closing does not reopen a failure", async () => {
		const copy = deferred<TrainingAnnouncement>();
		const h = harness(row(), { updateCopy: () => copy.promise });
		h.actor.send({ type: "SAVE", draft: editDraft({ title: "x" }) });
		h.actor.send({ type: "CLOSE" });
		copy.reject(problem("late refusal"));
		await Promise.resolve();
		await Promise.resolve();
		const snapshot = h.actor.getSnapshot();
		expect(snapshot.value).toBe("closed");
		expect(snapshot.context.problem).toBeNull();
	});

	it("closing from a resting state closes without any request", () => {
		const h = harness(row());
		h.actor.send({ type: "CLOSE" });
		expect(h.actor.getSnapshot().value).toBe("closed");
		expect(h.order).toEqual([]);
		expect(h.close).toHaveBeenCalledTimes(1);
	});
});
