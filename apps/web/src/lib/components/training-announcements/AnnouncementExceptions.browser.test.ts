import {
	configureClient,
	getClient,
	type TrainingAnnouncement,
	type TrainingAnnouncementOccurrence,
	type TrainingAnnouncementOverride,
	type TrainingAnnouncementSuppression,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import AnnouncementsRailTestWrapper from "./AnnouncementsRail.test-wrapper.svelte";

const TODAY = "2026-10-01"; // a Thursday
const ROLL_CALL_ID = "11111111-1111-1111-1111-111111111111";

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
		phase: "same_day",
		postTime: "10:00:00",
		kind: "roll_call",
		outcome: "post",
		chain: ["defaults"],
		decidedBy: "defaults",
		titleSource: "Roll call {{date}}",
		messageSource: "Hey!",
		mentionEveryone: true,
		renderedMessage: "@everyone\nRoll call Thursday 8 October 2026",
		threadName: "Roll call Thursday 8 October 2026",
		readOnly: false,
		renderErrors: [],
		delivery: null,
		...overrides,
	};
}

type Call = { method: string; url: string; body?: StubBody };

type StubBody = Partial<
	TrainingAnnouncementSuppression & TrainingAnnouncementOverride
>;

/** Every body the in-memory Phoenix can answer with. */
type StubPayload =
	| { data: TrainingAnnouncementSuppression | TrainingAnnouncementOverride }
	| { data: TrainingAnnouncementSuppression[] }
	| { data: TrainingAnnouncementOverride[] }
	| { data: TrainingAnnouncement[] }
	| { data: TrainingAnnouncementOccurrence[] }
	| { errors: { detail: string; fields?: Record<string, string[]> } };

type Script = {
	suppressions?: TrainingAnnouncementSuppression[];
	overrides?: TrainingAnnouncementOverride[];
	upcoming?: TrainingAnnouncementOccurrence[];
	reject?: { status: number; body: StubPayload };
	/** Holds removals until `releaseDelete` runs, then answers with `deleteReject`
	 * when set, so tests can read the optimistic list and its rollback. */
	deferDelete?: boolean;
	deleteReject?: { status: number; body: StubPayload };
};

function suppression(
	overrides: Partial<TrainingAnnouncementSuppression> = {},
): TrainingAnnouncementSuppression {
	return {
		id: "33333333-3333-3333-3333-333333333333",
		announcementId: ROLL_CALL_ID,
		fromDate: "2026-10-08",
		toDate: "2026-10-08",
		createdAt: "2026-09-01T10:00:00Z",
		...overrides,
	};
}

function override(
	overrides: Partial<TrainingAnnouncementOverride> = {},
): TrainingAnnouncementOverride {
	return {
		...suppression({
			id: "44444444-4444-4444-4444-444444444444",
		}),
		title: "Special session",
		message: null,
		...overrides,
	};
}

/**
 * Points the generated client at an in-memory Phoenix for the exceptions
 * slice and the per-announcement occurrence read. Each test gets its own
 * client, so one test's recorder can never be written to by another's
 * render.
 */
function useApi(script: Script = {}) {
	let suppressions = script.suppressions ?? [];
	let overridesList = script.overrides ?? [];
	const upcoming = script.upcoming ?? [occurrence()];
	const calls: Call[] = [];
	let releaseDelete: (() => void) | undefined;
	configureClient({ baseUrl: "/api", credentials: "include", retry: 0 });

	getClient().setConfig({
		kyOptions: {
			fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
				const request =
					input instanceof Request ? input : new Request(input, init);
				const url = request.url;
				const method = request.method.toUpperCase();
				let body: StubBody | undefined;
				if (method === "GET" || method === "HEAD") {
					body = undefined;
				} else {
					try {
						// SAFETY: the generated client validates every write body
						// against its request schema before this fetch runs, so
						// parsed JSON is the exception request shape this stub
						// echoes back.
						body = (await request.clone().json()) as StubBody;
					} catch {
						body = undefined;
					}
				}
				calls.push({ method, url, body });

				const json = (payload: StubPayload, status = 200) =>
					new Response(JSON.stringify(payload), {
						status,
						headers: { "content-type": "application/json" },
					});

				if (script.reject && method !== "GET")
					return json(script.reject.body, script.reject.status);

				if (method === "GET" && url.includes("/training-announcements")) {
					if (url.includes("/suppressions"))
						return json({ data: suppressions });
					if (url.includes("/overrides")) return json({ data: overridesList });
					if (url.includes("/occurrences")) return json({ data: upcoming });
					return json({ data: [announcement()] });
				}
				if (method === "POST" && url.includes("/suppressions")) {
					// SAFETY: the stub answers a created suppression by echoing
					// the validated request body with a fresh id, so the
					// partial body is the suppression shape by construction.
					const created = suppression({
						...(body as Partial<TrainingAnnouncementSuppression>),
						id: "55555555-5555-5555-5555-555555555555",
					});
					suppressions = [...suppressions, created];
					return json({ data: created }, 201);
				}
				if (method === "POST" && url.includes("/overrides")) {
					// SAFETY: as above, the echoed request body is the
					// validated override shape, so the partial is complete
					// once the stub stamps its id.
					const created = override({
						...(body as Partial<TrainingAnnouncementOverride>),
						id: "66666666-6666-6666-6666-666666666666",
					});
					overridesList = [...overridesList, created];
					return json({ data: created }, 201);
				}
				if (method === "DELETE" && script.deferDelete) {
					await new Promise<void>((resolve) => {
						releaseDelete = resolve;
					});
				}
				if (method === "DELETE" && script.deleteReject)
					return json(script.deleteReject.body, script.deleteReject.status);
				if (method === "DELETE" && url.includes("/suppressions/")) {
					const id = url.split("/").at(-1) ?? "";
					suppressions = suppressions.filter((row) => row.id !== id);
					return new Response(null, { status: 204 });
				}
				if (method === "DELETE" && url.includes("/overrides/")) {
					const id = url.split("/").at(-1) ?? "";
					overridesList = overridesList.filter((row) => row.id !== id);
					return new Response(null, { status: 204 });
				}
				return json({ errors: { detail: `${method} ${url}` } }, 404);
			},
		},
	});

	return { calls, releaseDelete: () => releaseDelete?.() };
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

async function openDetail(screen: Awaited<ReturnType<typeof renderRail>>) {
	await screen
		.getByRole("button", { name: /Manage posts for Roll call/ })
		.click();
	await expect.element(screen.getByTestId("announcement-detail")).toBeVisible();
	await expect
		.poll(() => document.activeElement?.id)
		.toBe("announcement-dates-and-copy");
	const detail = screen.container.querySelector("#announcement-dates-and-copy");
	const calendar = screen.container.querySelector(
		"[data-testid='training-calendar']",
	);
	expect(detail).not.toBeNull();
	expect(calendar).not.toBeNull();
	// Details are revealed before the calendar rather than below its entire grid.
	expect(
		detail!.compareDocumentPosition(calendar!) &
			Node.DOCUMENT_POSITION_FOLLOWING,
	).toBeTruthy();
}

/**
 * Pick a Dublin date through the shared date picker the way a reader does:
 * open the popover, then click the day cell. Replaces the `fill()` these tests
 * used on a native `type="date"` input, which no longer exists.
 */
async function pickDate(
	screen: Awaited<ReturnType<typeof renderRail>>,
	label: string,
	isoDate: string,
) {
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

test("detail lists render the resolved next title with capped counts", async () => {
	const suppressions = Array.from({ length: 7 }, (_, index) =>
		suppression({
			id: `3333333${index}-3333-3333-3333-33333333333${index}`,
			fromDate: `2026-10-${String(8 + index).padStart(2, "0")}`,
			toDate: `2026-10-${String(8 + index).padStart(2, "0")}`,
		}),
	);
	useApi({ suppressions, overrides: [override()] });
	const screen = await renderRail();
	await openDetail(screen);

	// The next post reads Phoenix's resolved thread name, not the template.
	await expect
		.element(screen.getByTestId("next-post"))
		.toHaveTextContent("Roll call Thursday 8 October 2026");
	// Seven skips collapse to the cap with a count.
	await expect.element(screen.getByText("Skipped dates")).toBeVisible();
	await expect.element(screen.getByText(/Showing 5 of 7 skips/)).toBeVisible();
	await expect.element(screen.getByText("Text changes")).toBeVisible();
});

test("creates a single-date suppression and removes it with confirmation", async () => {
	const api = useApi({ suppressions: [], overrides: [] });
	const screen = await renderRail();
	await openDetail(screen);

	await screen
		.getByRole("button", { name: /Skip dates for Roll call/ })
		.click();
	await pickDate(screen, "First date", "2026-10-15");
	await pickDate(screen, "Last date, inclusive", "2026-10-15");
	await screen.getByRole("button", { name: "Skip these dates" }).click();

	await expect
		.poll(() =>
			api.calls.some(
				(call) => call.method === "POST" && call.url.includes("/suppressions"),
			),
		)
		.toBe(true);
	await expect
		.element(screen.getByText("Thursday 15 October 2026"))
		.toBeVisible();

	// Removal asks first so a changed plan is easy to undo but hard to fat-finger.
	await screen
		.getByRole("button", { name: /Remove skip on Thursday 15/ })
		.click();
	await screen.getByRole("button", { name: /Confirm removing skip/ }).click();
	await expect
		.poll(() => api.calls.some((call) => call.method === "DELETE"))
		.toBe(true);
});

test("a removed skip leaves the list at once and returns if Phoenix refuses", async () => {
	const api = useApi({
		suppressions: [suppression()],
		overrides: [],
		deferDelete: true,
		deleteReject: {
			status: 422,
			body: { errors: { detail: "Delivery for this date has begun" } },
		},
	});
	const screen = await renderRail();
	await openDetail(screen);

	await screen
		.getByRole("button", { name: /Remove skip on Thursday 8/ })
		.click();
	await screen.getByRole("button", { name: /Confirm removing skip/ }).click();
	await expect
		.poll(() => api.calls.some((call) => call.method === "DELETE"))
		.toBe(true);
	// Phoenix has not answered, but the skip is already gone.
	await expect.element(screen.getByText("No skipped dates.")).toBeVisible();

	api.releaseDelete();
	await expect
		.element(screen.getByRole("button", { name: /Remove skip on Thursday 8/ }))
		.toBeVisible();
});

test("change copy inserts inline tags and removes them atomically before saving", async () => {
	const api = useApi({ suppressions: [], overrides: [] });
	const screen = await renderRail();
	await openDetail(screen);
	await screen
		.getByRole("button", { name: /Change text for Roll call/ })
		.click();
	const title = screen.getByRole("textbox", { name: "Title", exact: true });
	await title.fill("Special ");
	await screen
		.getByRole("button", { name: "Insert date into title", exact: true })
		.click();
	await expect.element(title).toHaveTextContent("Special Date");
	expect(
		screen
			.getByRole("button", { name: "Insert date into title", exact: true })
			.element()
			.getBoundingClientRect().height,
	).toBeLessThanOrEqual(24);
	expect(
		title
			.element()
			.querySelector('[data-placeholder="{{date}}"]')
			?.getAttribute("contenteditable"),
	).toBe("false");
	await userEvent.keyboard("{Backspace}");
	expect(title.element().querySelector("[data-placeholder]")).toBeNull();
	await screen
		.getByRole("button", { name: "Insert weekday into title", exact: true })
		.click();
	// The message arrives pre-filled with the announcement's current copy,
	// so the token appends to it rather than filling an empty field.
	await screen
		.getByRole("button", { name: "Insert title into message", exact: true })
		.click();
	const message = screen.getByRole("textbox", { name: "Message", exact: true });
	await expect.element(message).toHaveTextContent("Title");
	await screen
		.getByTestId("override-sheet")
		.getByRole("button", { name: "Change text", exact: true })
		.click();
	await expect
		.poll(() =>
			api.calls.some(
				(call) => call.method === "POST" && call.url.includes("/overrides"),
			),
		)
		.toBe(true);
	expect(
		api.calls.find(
			(call) => call.method === "POST" && call.url.includes("/overrides"),
		)?.body,
	).toMatchObject({
		title: "Special {{weekday}}",
		message:
			"Hey! It's {{weekday}}! Who is coming to training tonight? ⚔️{{title}}",
	});
});

test("creates a range override replacing the title", async () => {
	const api = useApi({ suppressions: [], overrides: [] });
	const screen = await renderRail();
	await openDetail(screen);

	await screen
		.getByRole("button", { name: /Change text for Roll call/ })
		.click();
	await pickDate(screen, "First date", "2026-10-08");
	await pickDate(screen, "Last date, inclusive", "2026-10-09");
	await screen
		.getByRole("textbox", { name: "Title", exact: true })
		.fill("Halloween special");
	// A title-only change: emptying the pre-filled message keeps the
	// announcement's existing message for these dates.
	await screen.getByRole("textbox", { name: "Message", exact: true }).fill("");
	await screen
		.getByTestId("override-sheet")
		.getByRole("button", { name: "Change text", exact: true })
		.click();

	await expect
		.poll(() =>
			api.calls.some(
				(call) => call.method === "POST" && call.url.includes("/overrides"),
			),
		)
		.toBe(true);
	const post = api.calls.find(
		(call) => call.method === "POST" && call.url.includes("/overrides"),
	);
	expect(post?.body).toMatchObject({
		fromDate: "2026-10-08",
		toDate: "2026-10-09",
		title: "Halloween special",
		message: null,
	});
	await expect.element(screen.getByText(/Replaces the title/)).toBeVisible();

	// Removal asks first, for copy changes too.
	await screen.getByRole("button", { name: /Remove text change on/ }).click();
	await screen
		.getByRole("button", { name: /Confirm removing text change/ })
		.click();
	await expect
		.poll(() =>
			api.calls.some(
				(call) => call.method === "DELETE" && call.url.includes("/overrides/"),
			),
		)
		.toBe(true);
});

test("past-date rejections render next to the form", async () => {
	useApi({
		reject: {
			status: 422,
			body: {
				errors: {
					detail: "fromDate: must be today or later in Dublin",
					fields: {
						fromDate: ["must be today or later in Dublin"],
					},
				},
			},
		},
	});
	const screen = await renderRail();
	await openDetail(screen);

	await screen
		.getByRole("button", { name: /Skip dates for Roll call/ })
		.click();
	// A date before the retention-relevant past is now unreachable through the
	// picker (`minValue` is today), so the refusal is still Phoenix's to make —
	// it can fire on a date that elapsed while the sheet was open. What this
	// asserts is unchanged: the field-scoped message renders against the field.
	await pickDate(screen, "First date", "2026-10-01");
	await pickDate(screen, "Last date, inclusive", "2026-10-01");
	await screen
		.getByTestId("suppression-sheet")
		.getByRole("button", { name: "Skip these dates" })
		.click();

	// The past is never reinterpreted, and the refusal stays in the sheet.
	await expect
		.element(screen.getByText("must be today or later in Dublin").first())
		.toBeVisible();
	await expect
		.element(
			screen
				.getByTestId("suppression-sheet")
				.getByRole("button", { name: "Skip these dates" }),
		)
		.toBeVisible();
});

test("overlap rejections render next to the form", async () => {
	useApi({
		reject: {
			status: 422,
			body: {
				errors: {
					detail: "fromDate: overlaps another override for this announcement",
					fields: {
						fromDate: ["overlaps another override for this announcement"],
					},
				},
			},
		},
	});
	const screen = await renderRail();
	await openDetail(screen);

	await screen
		.getByRole("button", { name: /Change text for Roll call/ })
		.click();
	await screen
		.getByRole("textbox", { name: "Title", exact: true })
		.fill("Special session");
	await screen
		.getByTestId("override-sheet")
		.getByRole("button", { name: "Change text", exact: true })
		.click();

	// The rejection stays in the sheet, against the form — never a toast —
	// reworded as the way out: the existing text change must be deleted
	// before a new one can cover its dates.
	await expect
		.element(
			screen
				.getByText(
					"These dates overlap an existing text change. Delete the existing text change before creating a new one.",
				)
				.first(),
		)
		.toBeVisible();
	await expect
		.element(
			screen
				.getByTestId("override-sheet")
				.getByRole("button", { name: "Change text", exact: true }),
		)
		.toBeVisible();
});
