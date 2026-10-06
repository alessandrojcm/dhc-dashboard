import {
	configureClient,
	getClient,
	type TrainingAnnouncement,
	type TrainingAnnouncementOccurrence,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { expect, test } from "vitest";
import type { Locator } from "vitest/browser";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import AnnouncementsRailTestWrapper from "./AnnouncementsRail.test-wrapper.svelte";

const TODAY = "2026-10-01"; // a Thursday
const ROLL_CALL_ID = "11111111-1111-1111-1111-111111111111";
const SPARRING_ID = "22222222-2222-2222-2222-222222222222";

function announcement(
	overrides: Partial<TrainingAnnouncement> = {},
): TrainingAnnouncement {
	return {
		id: ROLL_CALL_ID,
		kind: "roll_call",
		weekday: 4,
		oneOffDate: null,
		postTime: "10:00:00",
		title: "Roll call {{date}}",
		message: "Hey! It's {{weekday}}! Who is coming to training tonight? ⚔️",
		mentionEveryone: true,
		enabled: true,
		retired: false,
		firstAttemptedAt: null,
		createdAt: "2026-09-01T10:00:00Z",
		updatedAt: "2026-09-01T10:00:00Z",
		...overrides,
	};
}

type Call = { method: string; url: string; body?: unknown };

type AnnouncementApi = {
	/** Every request the page made, in order. */
	calls: Call[];
	/** The list Phoenix would answer with right now. */
	rows: () => TrainingAnnouncement[];
	/** Answers a deferred create (only when `deferCreate` is set). */
	releaseCreate: () => void;
	/** Answers a deferred lifecycle command (only when `deferCommands` is set). */
	releaseCommand: () => void;
};

/** Every body the in-memory Phoenix can answer with. */
type StubPayload =
	| { data: TrainingAnnouncement | TrainingAnnouncement[] }
	| { data: TrainingAnnouncementOccurrence[] }
	| {
			data: {
				announcement: TrainingAnnouncement;
				warnings: string[];
			};
	  }
	| { data: { renderedMessage: string; threadName: string } }
	| {
			errors: {
				detail: string;
				fields?: Record<string, string[]>;
			};
	  };

type Script = {
	rows?: TrainingAnnouncement[];
	/** Warnings the create/schedule response carries. */
	warnings?: string[];
	/** A rejected write, as Phoenix renders problem details. */
	reject?: { status: number; body: StubPayload };
	preview?: { renderedMessage: string; threadName: string };
	/** Holds the create response until `releaseCreate` runs, so tests can
	 * read the rail while the write is still in flight. */
	deferCreate?: boolean;
	/** Holds lifecycle commands (disable/enable/retire/delete) until
	 * `releaseCommand` runs, so tests can read the optimistic rail. */
	deferCommands?: boolean;
	/** Refuses only lifecycle commands; reads keep answering, unlike `reject`. */
	rejectCommands?: { status: number; body: StubPayload };
	/** What `listForAnnouncement` answers per direction. */
	occurrences?: {
		upcoming?: TrainingAnnouncementOccurrence[];
		recent?: TrainingAnnouncementOccurrence[];
	};
};

/**
 * Points the generated client at an in-memory Phoenix for the `trainingAnnouncements`
 * slice. Each test gets its own client, so one test's recorder can never be
 * written to by another's render — the page fetches the list as soon as it mounts.
 */
function useApi(script: Script = {}): AnnouncementApi {
	const {
		rows: seeded = [],
		warnings = [],
		reject,
		occurrences = {},
		deferCreate = false,
		deferCommands = false,
		rejectCommands,
		preview = {
			renderedMessage: "@everyone\nRoll call Thursday 8 October 2026",
			threadName: "Roll call Thursday 8 October 2026",
		},
	} = script;
	let rows = seeded;
	let releaseCreate: (() => void) | undefined;
	let releaseCommand: (() => void) | undefined;
	const calls: Call[] = [];
	configureClient({ baseUrl: "/api", credentials: "include", retry: 0 });

	getClient().setConfig({
		kyOptions: {
			fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
				// ky hands the interceptor a Request, or the raw parts; read the
				// body off whichever shape arrived so write assertions can see it.
				const request =
					input instanceof Request ? input : new Request(input, init);
				const url = request.url;
				const method = request.method.toUpperCase();
				let body: Partial<TrainingAnnouncement> | undefined;
				if (method === "GET" || method === "HEAD") {
					body = undefined;
				} else {
					try {
						// SAFETY: the generated client validates every write body against
						// its request schema before this fetch runs, so parsed JSON is
						// the announcement request shape this stub merges.
						body = (await request
							.clone()
							.json()) as Partial<TrainingAnnouncement>;
					} catch {
						// Lifecycle commands and DELETE send no body, and `.json()` on
						// an empty body rejects — record that as "no body" so the call
						// is still answered instead of failing like a network error.
						body = undefined;
					}
				}
				calls.push({ method, url, body });

				const json = (payload: StubPayload, status = 200) =>
					new Response(JSON.stringify(payload), {
						status,
						headers: { "content-type": "application/json" },
					});

				const isCommand =
					(method === "POST" && /\/(disable|enable|retire)$/.test(url)) ||
					(method === "DELETE" && url.includes("/training-announcements/"));
				if (deferCommands && isCommand) {
					await new Promise<void>((resolve) => {
						releaseCommand = resolve;
					});
				}
				if (rejectCommands && isCommand)
					return json(rejectCommands.body, rejectCommands.status);

				if (reject) return json(reject.body, reject.status);

				// ALE-332: the calendar reads every occurrence in view through
				// `window`, and each card reads its next posts and recent
				// deliveries. These tests assert the rail, not those reads.
				if (method === "GET" && url.includes("/occurrences/window")) {
					return json({ data: [] });
				}
				if (method === "GET" && url.includes("/occurrences")) {
					const direction = new URL(url).searchParams.get("direction");
					if (direction === "recent")
						return json({ data: occurrences.recent ?? [] });
					return json({ data: occurrences.upcoming ?? [] });
				}
				if (method === "GET" && url.includes("/training-announcements")) {
					// `list` excludes retired unless asked, like Phoenix's own default.
					return json({
						data: url.includes("includeRetired=true")
							? rows
							: rows.filter((row) => !row.retired),
					});
				}
				if (method === "POST" && url.endsWith("/preview-copy")) {
					return json({ data: preview });
				}
				if (method === "POST" && url.endsWith("/training-announcements")) {
					if (deferCreate) {
						// The executor runs synchronously, so the releaser is
						// set before the recorded call is visible to the test.
						await new Promise<void>((resolve) => {
							releaseCreate = resolve;
						});
					}
					const created = announcement({
						...(body ?? {}),
						id: SPARRING_ID,
					});
					rows = [...rows, created];
					return json({ data: { announcement: created, warnings } }, 201);
				}
				if (method === "POST" && url.includes("/disable")) {
					return json({ data: toggle(url, "disable") });
				}
				if (method === "POST" && url.includes("/enable")) {
					return json({ data: toggle(url, "enable") });
				}
				if (method === "POST" && url.includes("/retire")) {
					return json({ data: toggle(url, "retire") });
				}
				if (method === "DELETE" && url.includes("/training-announcements/")) {
					const id = url.split("/").at(-1) ?? "";
					rows = rows.filter((row) => row.id !== id);
					return new Response(null, { status: 204 });
				}
				if (method === "PUT" && url.includes("/schedule")) {
					return json({
						data: { announcement: applyUpdate(url, body ?? {}), warnings },
					});
				}
				if (method === "PUT" && url.includes("/copy")) {
					return json({ data: applyUpdate(url, body ?? {}) });
				}
				return json({ errors: { detail: `${method} ${url}` } }, 404);
			},
		},
	});

	function idFrom(url: string): string {
		return url.split("/").at(-2) ?? "";
	}

	function applyUpdate(
		url: string,
		changes: Partial<TrainingAnnouncement>,
	): TrainingAnnouncement {
		const id = idFrom(url);
		rows = rows.map((row) => (row.id === id ? { ...row, ...changes } : row));
		const updated = rows.find((row) => row.id === id);
		if (!updated) throw new Error(`no announcement ${id}`);
		return updated;
	}

	function toggle(
		url: string,
		action: "disable" | "enable" | "retire",
	): TrainingAnnouncement {
		const id = idFrom(url);
		if (action === "retire") {
			rows = rows.map((row) =>
				row.id === id ? { ...row, retired: true } : row,
			);
		} else {
			rows = rows.map((row) =>
				row.id === id ? { ...row, enabled: action === "enable" } : row,
			);
		}
		const updated = rows.find((row) => row.id === id);
		if (!updated) throw new Error(`no announcement ${id}`);
		return updated;
	}

	return {
		calls,
		rows: () => rows,
		releaseCreate: () => releaseCreate?.(),
		releaseCommand: () => releaseCommand?.(),
	};
}

function renderRail() {
	const queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false, staleTime: Infinity, refetchOnMount: false },
			mutations: { retry: false },
		},
	});
	return render(AnnouncementsRailTestWrapper, { today: TODAY, queryClient });
}

function callBody(
	api: AnnouncementApi,
	method: string,
	path: string,
): Call["body"] {
	const call = api.calls.find(
		(entry) => entry.method === method && entry.url.includes(path),
	);
	if (!call) {
		throw new Error(
			`no ${method} call to ${path}: ${JSON.stringify(api.calls)}`,
		);
	}
	return call.body;
}

/** `true` once nothing with that accessible name is left in the DOM. */
async function gone(locator: Locator): Promise<boolean> {
	return (await locator.query()) === null;
}

/**
 * Pick a Dublin date through the shared date picker the way a reader does: open
 * the popover, then click the day cell. Replaces the `fill()` these tests used
 * on a native `type="date"` input, which no longer exists.
 */
async function pickDate(
	screen: Awaited<ReturnType<typeof renderRail>>,
	label: string,
	isoDate: string,
) {
	// Scoped to the button's exact accessible name: "Date" is a prefix of
	// "Preview date", and both are date pickers on this form.
	await screen.getByRole("button", { name: label, exact: true }).click();
	// bits-ui labels each day button with its full date, which disambiguates a
	// day number that an adjacent month repeats.
	await screen.getByRole("button", { name: dayLabel(isoDate) }).click();
}

/** The accessible name bits-ui gives a `Calendar` day button. */
function dayLabel(isoDate: string): string {
	const [year, month, day] = isoDate.split("-").map(Number);
	// SAFETY: every caller passes a `YYYY-MM-DD` literal, so the parts are
	// numbers; `!` keeps the destructuring honest without a runtime guard.
	const date = new Date(year!, month! - 1, day!);
	return new Intl.DateTimeFormat("en-US", {
		weekday: "long",
		month: "long",
		day: "numeric",
		year: "numeric",
	}).format(date);
}

test("creates a weekly roll call pre-filled with the kind's preset", async () => {
	const api = useApi({ rows: [] });
	const screen = await renderRail();

	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();

	// The kind's copy is pre-filled, so cutover needs no wording. The preset
	// text itself is owned by the copy module and its tests.
	expect(
		screen.getByTestId("announcement-sheet").element().textContent,
	).not.toContain("Europe/Dublin");
	await expect
		.element(screen.getByRole("radio", { name: /^Roll call/ }))
		.toBeChecked();

	await screen.getByRole("button", { name: "Create announcement" }).click();

	await expect
		.poll(() => api.calls.some((call) => call.method === "POST"))
		.toBe(true);
	expect(callBody(api, "POST", "/training-announcements")).toEqual({
		kind: "roll_call",
		weekday: expect.any(Number),
		oneOffDate: null,
		postTime: expect.any(String),
		title: expect.stringMatching(/\S/),
		message: expect.stringMatching(/\S/),
		mentionEveryone: expect.any(Boolean),
	});
	await expect
		.element(screen.getByRole("button", { name: /Manage posts for Roll call/ }))
		.toBeVisible();
	expect(screen.container.textContent).not.toContain("Europe/Dublin");
});

test("new announcements appear optimistically while the create is in flight", async () => {
	const api = useApi({ rows: [], deferCreate: true });
	const screen = await renderRail();

	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	await screen.getByRole("button", { name: "Create announcement" }).click();

	// The write has reached Phoenix but Phoenix has not answered yet.
	await expect
		.poll(() =>
			api.calls.some(
				(call) =>
					call.method === "POST" &&
					call.url.endsWith("/training-announcements"),
			),
		)
		.toBe(true);
	// The card is already in the rail, with the draft's copy.
	await expect
		.element(screen.getByRole("heading", { name: "Roll call {{date}}" }))
		.toBeVisible();

	// Phoenix answers: the temporary card resolves to the saved row and the
	// sheet closes.
	api.releaseCreate();
	await expect
		.element(screen.getByRole("button", { name: /Manage posts for Roll call/ }))
		.toBeVisible();
});

test("placeholder buttons insert at the cursor, replace selections, and save template copy", async () => {
	const api = useApi();
	const screen = await renderRail();
	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	await screen
		.getByRole("textbox", { name: "Title" })
		.fill("Roll call tonight");
	const title = screen.getByRole("textbox", { name: "Title" }).element();
	const titleRange = document.createRange();
	titleRange.setStart(title.firstChild!, 10);
	titleRange.setEnd(title.firstChild!, 17);
	window.getSelection()!.removeAllRanges();
	window.getSelection()!.addRange(titleRange);
	await screen
		.getByRole("button", { name: "Insert date into title", exact: true })
		.click();
	await expect
		.element(screen.getByRole("textbox", { name: "Title" }))
		.toHaveTextContent("Roll call Date");
	expect(document.activeElement).toBe(title);
	expect(
		title
			.querySelector('[data-placeholder="{{date}}"]')
			?.getAttribute("contenteditable"),
	).toBe("false");

	await screen
		.getByRole("textbox", { name: "Message", exact: true })
		.fill("Join us on  for training");
	const message = screen
		.getByRole("textbox", { name: "Message", exact: true })
		.element();
	const messageRange = document.createRange();
	messageRange.setStart(message.firstChild!, 11);
	messageRange.collapse(true);
	window.getSelection()!.removeAllRanges();
	window.getSelection()!.addRange(messageRange);
	// Keyboard activation works too, and returns focus to the text field.
	const weekday = screen.getByRole("button", {
		name: "Insert weekday into message",
		exact: true,
	});
	const weekdayButton = weekday.element();
	if (!(weekdayButton instanceof HTMLButtonElement))
		throw new Error("Expected a placeholder button");
	weekdayButton.focus();
	await userEvent.keyboard("{Enter}");
	await expect
		.element(screen.getByRole("textbox", { name: "Message", exact: true }))
		.toHaveTextContent("Join us on Weekday for training");
	expect(document.activeElement).toBe(message);
	expect(
		message.querySelector('[data-placeholder="{{weekday}}"]'),
	).not.toBeNull();

	await screen.getByRole("button", { name: "Create announcement" }).click();
	await expect.poll(() => api.rows().length).toBe(1);
	expect(callBody(api, "POST", "/training-announcements")).toMatchObject({
		title: "Roll call {{date}}",
		message: "Join us on {{weekday}} for training",
	});
});

test("placeholder insertion preserves the title length limit", async () => {
	useApi();
	const screen = await renderRail();
	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	await screen.getByRole("textbox", { name: "Title" }).fill("a".repeat(100));
	await screen
		.getByRole("button", { name: "Insert date into title", exact: true })
		.click();
	await expect
		.element(screen.getByRole("textbox", { name: "Title" }))
		.toHaveTextContent("a".repeat(100));
	await expect
		.element(screen.getByText(/Make room in the title/))
		.toBeVisible();
});

test("inline placeholder tags delete atomically and undo restores them", async () => {
	const api = useApi();
	const screen = await renderRail();
	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	const title = screen.getByRole("textbox", { name: "Title", exact: true });
	await title.fill("Training: ");
	await screen
		.getByRole("button", { name: "Insert date into title", exact: true })
		.click();
	await expect.element(title).toHaveTextContent("Training: Date");
	await userEvent.keyboard("{Backspace}");
	await expect.element(title).toHaveTextContent("Training:");
	expect(title.element().querySelector("[data-placeholder]")).toBeNull();
	await userEvent.keyboard("{Control>}z{/Control}");
	await expect.element(title).toHaveTextContent("Training: Date");
	await userEvent.keyboard("{ArrowLeft}{Delete}");
	await expect.element(title).toHaveTextContent("Training:");
	await screen.getByRole("button", { name: "Create announcement" }).click();
	await expect.poll(() => api.rows().length).toBe(1);
	expect(callBody(api, "POST", "/training-announcements")).toMatchObject({
		title: "Training: ",
	});
});

test("message tags preserve line breaks and preset changes reset editing history", async () => {
	const api = useApi();
	const screen = await renderRail();
	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	const message = screen.getByRole("textbox", { name: "Message", exact: true });
	await message.fill("Hello");
	await userEvent.keyboard("{Enter}");
	await screen
		.getByRole("button", { name: "Insert title into message", exact: true })
		.click();
	await screen.getByRole("button", { name: "Preview", exact: true }).click();
	await expect
		.poll(() => api.calls.some((call) => call.url.endsWith("/preview-copy")))
		.toBe(true);
	expect(callBody(api, "POST", "/preview-copy")).toMatchObject({
		message: "Hello\n{{title}}",
	});
	await screen.getByRole("radio", { name: /^Sparring/ }).click();
	await message.click();
	await userEvent.keyboard("{Control>}z{/Control}");
	await expect
		.element(message)
		.toHaveTextContent("Hey! Who is down for sparring next Sunday? ⚔️");
});

test("creates a one-off with the sparring copy", async () => {
	const api = useApi({ rows: [] });
	const screen = await renderRail();

	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	await screen.getByRole("radio", { name: /^Sparring/ }).click();
	await screen.getByRole("radio", { name: "One-off" }).click();
	await pickDate(screen, "Date", "2026-10-09");
	await screen.getByLabelText("Post time").fill("18:30");

	await screen.getByRole("button", { name: "Create announcement" }).click();

	await expect
		.poll(() =>
			api.calls.some(
				(call) =>
					call.method === "POST" &&
					call.url.endsWith("/training-announcements"),
			),
		)
		.toBe(true);
	expect(callBody(api, "POST", "/training-announcements")).toMatchObject({
		kind: "sparring",
		weekday: null,
		oneOffDate: "2026-10-09",
		postTime: "18:30",
		title: "Sparring {{date}}",
	});
});

test("previews the rendered message and thread name without posting", async () => {
	const api = useApi({ rows: [] });
	const screen = await renderRail();

	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	await screen.getByRole("button", { name: "Preview", exact: true }).click();

	const preview = screen.getByRole("group", { name: "Discord preview" });
	// The preview posts as the real bot account, as Discord will.
	await expect
		.element(preview.getByText("The Muffin Man", { exact: true }))
		.toBeVisible();
	await expect.element(preview.getByText(/@everyone/)).toBeVisible();
	await expect
		.element(preview.getByText("Roll call Thursday 8 October 2026").first())
		.toBeVisible();
	expect(
		api.calls.some(
			(call) => call.method !== "GET" && !call.url.includes("preview-copy"),
		),
	).toBe(false);
});

test("keeps the kind fixed when editing an existing announcement", async () => {
	const api = useApi({
		rows: [
			announcement({
				id: SPARRING_ID,
				kind: "sparring",
				title: "Sparring {{date}}",
				message: "Hey! Who is down for sparring next Sunday? ⚔️",
			}),
		],
	});
	const screen = await renderRail();

	await screen.getByRole("button", { name: /^Edit Sparring/ }).click();

	await expect
		.element(screen.getByRole("radio", { name: /^Sparring/ }))
		.toBeDisabled();
	await expect
		.element(screen.getByRole("radio", { name: /^Roll call/ }))
		.toBeDisabled();
});

test("shows create warnings without blocking the saved announcement", async () => {
	const api = useApi({ rows: [], warnings: ["slot_collision"] });
	const screen = await renderRail();

	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	await screen.getByRole("button", { name: "Create announcement" }).click();

	await expect
		.element(
			screen.getByText(/Another announcement is scheduled for the same time/),
		)
		.toBeVisible();
	await expect
		.element(screen.getByRole("heading", { name: "Roll call {{date}}" }))
		.toBeVisible();
});

test("renders a not-elapsed rejection against the post time field", async () => {
	const api = useApi({
		rows: [],
		reject: {
			status: 422,
			body: {
				errors: {
					detail:
						"postTime: the first send instant has elapsed; choose a future Dublin date or time",
					fields: {
						postTime: [
							"the first send instant has elapsed; choose a future Dublin date or time",
						],
					},
				},
			},
		},
	});
	const screen = await renderRail();

	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	await screen.getByRole("button", { name: "Create announcement" }).click();

	await expect
		.element(
			screen
				.getByText(
					"the first send instant has elapsed; choose a future Dublin date or time",
				)
				.first(),
		)
		.toBeVisible();
	// The sheet stays open so the time can be corrected.
	await expect
		.element(screen.getByRole("button", { name: "Create announcement" }))
		.toBeVisible();
});

test("pauses and resumes an announcement from the card switch", async () => {
	const api = useApi({ rows: [announcement()] });
	const screen = await renderRail();

	await screen.getByRole("switch", { name: /Posting for Roll call/ }).click();

	await expect
		.poll(() =>
			api.calls.some(
				(call) => call.method === "POST" && call.url.includes("/disable"),
			),
		)
		.toBe(true);
	await expect
		.element(screen.getByText("Paused", { exact: true }))
		.toBeVisible();

	await screen.getByRole("switch", { name: /Posting for Roll call/ }).click();
	await expect
		.poll(() =>
			api.calls.some(
				(call) => call.method === "POST" && call.url.includes("/enable"),
			),
		)
		.toBe(true);
	await expect.element(screen.getByText("Live", { exact: true })).toBeVisible();
});

test("explains why an announcement that already posted cannot be deleted", async () => {
	const api = useApi({
		rows: [announcement({ firstAttemptedAt: "2026-09-24T10:00:00Z" })],
	});
	const screen = await renderRail();

	await expect
		.element(screen.getByRole("button", { name: /^Delete Roll call/ }))
		.toBeDisabled();
	await expect
		.element(screen.getByText(/Posting has already been attempted/))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: /^Retire Roll call/ }))
		.toBeEnabled();
});

test("retires an announcement and hides it until retired are shown", async () => {
	const api = useApi({ rows: [announcement()] });
	const screen = await renderRail();

	await screen.getByRole("button", { name: /^Retire Roll call/ }).click();

	await expect
		.poll(() =>
			api.calls.some(
				(call) => call.method === "POST" && call.url.includes("/retire"),
			),
		)
		.toBe(true);
	await expect
		.poll(() =>
			gone(screen.getByRole("heading", { name: "Roll call {{date}}" })),
		)
		.toBe(true);

	await screen.getByRole("switch", { name: "Show retired" }).click();
	await expect
		.element(screen.getByRole("heading", { name: "Roll call {{date}}" }))
		.toBeVisible();
	expect(
		api.calls.some(
			(call) =>
				call.method === "GET" && call.url.includes("includeRetired=true"),
		),
	).toBe(true);
});

test("deletes an announcement that has never posted", async () => {
	const api = useApi({ rows: [announcement()] });
	const screen = await renderRail();

	await screen.getByRole("button", { name: /^Delete Roll call/ }).click();

	await expect
		.poll(() =>
			api.calls.some(
				(call) => call.method === "DELETE" && call.url.includes(ROLL_CALL_ID),
			),
		)
		.toBe(true);
	await expect
		.poll(() =>
			gone(screen.getByRole("heading", { name: "Roll call {{date}}" })),
		)
		.toBe(true);
});

test("lifecycle commands update the rail before Phoenix answers", async () => {
	const api = useApi({
		rows: [
			announcement(),
			announcement({ id: SPARRING_ID, title: "Sparring" }),
		],
		deferCommands: true,
	});
	const screen = await renderRail();

	await screen.getByRole("switch", { name: /Posting for Roll call/ }).click();
	await expect
		.poll(() => api.calls.some((call) => call.url.endsWith("/disable")))
		.toBe(true);
	// Phoenix has not answered, but the card already reads as paused.
	await expect
		.element(screen.getByText("Paused", { exact: true }))
		.toBeVisible();
	api.releaseCommand();

	await screen.getByRole("button", { name: /^Delete Sparring/ }).click();
	await expect
		.poll(() => api.calls.some((call) => call.method === "DELETE"))
		.toBe(true);
	await expect
		.poll(() => gone(screen.getByRole("heading", { name: "Sparring" })))
		.toBe(true);
	api.releaseCommand();

	await screen.getByRole("button", { name: /^Retire Roll call/ }).click();
	await expect
		.poll(() => api.calls.some((call) => call.url.endsWith("/retire")))
		.toBe(true);
	await expect
		.poll(() =>
			gone(screen.getByRole("heading", { name: "Roll call {{date}}" })),
		)
		.toBe(true);
	api.releaseCommand();
});

test("a refused lifecycle command restores the card", async () => {
	const api = useApi({
		rows: [announcement()],
		deferCommands: true,
		rejectCommands: {
			status: 409,
			body: { errors: { detail: "Posting has already been attempted" } },
		},
	});
	const screen = await renderRail();

	await screen.getByRole("button", { name: /^Delete Roll call/ }).click();
	await expect
		.poll(() => api.calls.some((call) => call.method === "DELETE"))
		.toBe(true);
	await expect
		.poll(() =>
			gone(screen.getByRole("heading", { name: "Roll call {{date}}" })),
		)
		.toBe(true);

	api.releaseCommand();
	await expect
		.element(screen.getByRole("heading", { name: "Roll call {{date}}" }))
		.toBeVisible();
});

function occurrence(
	overrides: Partial<TrainingAnnouncementOccurrence> = {},
): TrainingAnnouncementOccurrence {
	return {
		subject: "occurrence",
		date: "2026-10-08",
		announcementId: ROLL_CALL_ID,
		appliedSuppressionId: null,
		appliedOverrideId: null,
		holidayDate: null,
		phase: null,
		postTime: "10:00:00",
		kind: "roll_call",
		outcome: "post",
		chain: ["disablement", "suppression", "override", "defaults"],
		decidedBy: "defaults",
		titleSource: "Roll call {{date}}",
		messageSource: "Who is coming?",
		mentionEveryone: true,
		renderedMessage: "@everyone\nRoll call Thursday 8 October 2026",
		threadName: "Roll call Thursday 8 October 2026",
		readOnly: false,
		renderErrors: [],
		delivery: null,
		...overrides,
	};
}

test("each card shows next posts and recent deliveries with display statuses", async () => {
	useApi({
		rows: [announcement()],
		occurrences: {
			upcoming: [occurrence()],
			recent: [
				occurrence({
					date: "2026-09-24",
					outcome: "post_override",
					threadName: "Special roll call Thursday 24 September 2026",
					delivery: {
						id: "33333333-3333-3333-3333-333333333333",
						state: "delivered",
						reason: "unknown",
						frozenAt: "2026-09-24T09:59:00Z",
						postingStartedAt: "2026-09-24T10:00:00Z",
						messagePostedAt: "2026-09-24T10:00:05Z",
						threadCreatedAt: "2026-09-24T10:00:09Z",
						concludedAt: "2026-09-24T10:00:10Z",
						discordMessageId: "234567890123456789",
						discordThreadId: "345678901234567890",
						permalink: "https://discord.com/channels/1/2/234567890123456789",
						errorDetail: null,
						threadAttempts: 1,
						lastThreadError: null,
						appliedSuppressionId: null,
						appliedOverrideId: null,
					},
				}),
			],
		},
	});
	const screen = await renderRail();

	// The card names the next post by its resolved title with the grouped
	// display status — never the announcement's template.
	await expect
		.element(screen.getByText("Roll call Thursday 8 October 2026").first())
		.toBeVisible();
	await expect.element(screen.getByText("scheduled").first()).toBeVisible();

	// …and the recent delivery reads from its evidence, not the projection.
	await expect
		.element(
			screen.getByText("Special roll call Thursday 24 September 2026").first(),
		)
		.toBeVisible();
	await expect.element(screen.getByText("posted").first()).toBeVisible();
});

test("a roll call's next posts include the holiday notices it drives", async () => {
	const notice = (date: string, phase: "day_before" | "same_day") =>
		occurrence({
			subject: "holiday",
			date,
			announcementId: null,
			holidayDate: "2026-10-08",
			phase,
			kind: null,
			chain: ["holiday"],
			decidedBy: "holiday",
			titleSource: null,
			messageSource: null,
			renderedMessage: "@everyone\nNo training",
			threadName: null,
			readOnly: true,
		});
	useApi({
		rows: [announcement()],
		occurrences: {
			upcoming: [
				notice("2026-10-07", "day_before"),
				notice("2026-10-08", "same_day"),
				occurrence({
					outcome: "skipped_holiday",
					chain: ["holiday"],
					decidedBy: "holiday",
				}),
			],
		},
	});
	const screen = await renderRail();

	const nextPosts = screen.getByTestId("card-next-posts");
	await expect.element(nextPosts).toBeVisible();
	await expect
		.poll(
			() =>
				nextPosts.getByText("Holiday notice", { exact: true }).elements()
					.length,
		)
		.toBe(2);
	await expect.element(nextPosts.getByText("bank holiday")).toBeVisible();

	await screen
		.getByRole("button", { name: /Manage posts for Roll call/ })
		.click();
	await expect
		.element(screen.getByTestId("next-post"))
		.toHaveTextContent(/Next post: Holiday notice on/);
});

test("the roll call form says holiday notices replace it on bank holidays", async () => {
	useApi({ rows: [] });
	const screen = await renderRail();
	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	await expect.element(screen.getByTestId("holiday-notice-hint")).toBeVisible();

	await screen.getByRole("radio", { name: /^Sparring/ }).click();
	await expect
		.poll(() => gone(screen.getByTestId("holiday-notice-hint")))
		.toBe(true);
});
