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
import { render } from "vitest-browser-svelte";
import AnnouncementsRailTestWrapper from "./AnnouncementsRail.test-wrapper.svelte";

const TODAY = "2026-10-01"; // a Thursday
const ROLL_CALL_ID = "11111111-1111-1111-1111-111111111111";
const OVERRIDE_ID = "44444444-4444-4444-4444-444444444444";

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
		phase: null,
		postTime: "10:00:00",
		kind: "roll_call",
		outcome: "post",
		chain: ["holiday", "disablement", "suppression", "override", "defaults"],
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

function deliveredPast(): TrainingAnnouncementOccurrence {
	return occurrence({
		date: "2026-09-29",
		outcome: "post_override",
		chain: ["disablement", "suppression", "override"],
		decidedBy: "override",
		threadName: "Special copy Tuesday 29 September 2026",
		renderedMessage: "@everyone\nSpecial copy Tuesday 29 September 2026",
		appliedOverrideId: OVERRIDE_ID,
		delivery: {
			id: "22222222-2222-2222-2222-222222222222",
			state: "delivered",
			reason: null,
			frozenAt: "2026-09-29T09:59:00Z",
			postingStartedAt: "2026-09-29T10:00:00Z",
			messagePostedAt: "2026-09-29T10:00:05Z",
			threadCreatedAt: "2026-09-29T10:00:10Z",
			concludedAt: "2026-09-29T10:00:12Z",
			discordMessageId: "234567890123456789",
			discordThreadId: "345678901234567890",
			permalink: "https://discord.com/channels/1/2/234567890123456789",
			errorDetail: null,
			threadAttempts: 2,
			lastThreadError: "Thread timeout",
			appliedSuppressionId: null,
			appliedOverrideId: OVERRIDE_ID,
		},
	});
}

function inFlight(): TrainingAnnouncementOccurrence {
	return occurrence({
		date: "2026-10-01",
		threadName: "Roll call Thursday 1 October 2026",
		renderedMessage: "@everyone\nRoll call Thursday 1 October 2026",
		delivery: {
			id: "33333333-3333-3333-3333-333333333333",
			state: "frozen",
			reason: null,
			frozenAt: "2026-10-01T09:59:00Z",
			postingStartedAt: null,
			messagePostedAt: null,
			threadCreatedAt: null,
			concludedAt: null,
			discordMessageId: null,
			discordThreadId: null,
			permalink: null,
			errorDetail: null,
			threadAttempts: 0,
			lastThreadError: null,
			appliedSuppressionId: null,
			appliedOverrideId: null,
		},
	});
}

function holidayItem(): TrainingAnnouncementOccurrence {
	return occurrence({
		subject: "holiday",
		date: "2026-10-26",
		announcementId: null,
		holidayDate: "2026-10-26",
		phase: "same_day",
		kind: null,
		outcome: "post",
		chain: ["holiday"],
		decidedBy: "holiday",
		titleSource: null,
		messageSource: null,
		mentionEveryone: true,
		renderedMessage: "No training — bank holiday",
		threadName: "No training Monday 26 October 2026",
		readOnly: true,
	});
}

type Call = { method: string; url: string; body?: StubBody };

type StubBody = Partial<
	TrainingAnnouncementSuppression & TrainingAnnouncementOverride
>;

function suppression(
	overrides: Partial<TrainingAnnouncementSuppression> = {},
): TrainingAnnouncementSuppression {
	return {
		id: "55555555-5555-5555-5555-555555555555",
		announcementId: ROLL_CALL_ID,
		fromDate: "2026-10-08",
		toDate: "2026-10-08",
		createdAt: "2026-10-01T10:00:00Z",
		...overrides,
	};
}

function override(
	overrides: Partial<TrainingAnnouncementOverride> = {},
): TrainingAnnouncementOverride {
	return {
		...suppression({
			id: "66666666-6666-6666-6666-666666666666",
		}),
		title: "Halloween special",
		message: null,
		...overrides,
	};
}

/** Every body the in-memory Phoenix can answer with. */
type StubPayload =
	| { data: TrainingAnnouncementSuppression | TrainingAnnouncementOverride }
	| { data: TrainingAnnouncementSuppression[] }
	| { data: TrainingAnnouncementOverride[] }
	| { data: TrainingAnnouncement[] }
	| { data: TrainingAnnouncementOccurrence[] }
	| { errors: { detail: string; fields?: Record<string, string[]> } };

/**
 * Points the generated client at an in-memory Phoenix serving the rail, the
 * `window` read model and the exceptions slice. The window items are
 * stateful: creating a single-date suppression rewrites the matching
 * occurrence to `skipped_suppressed`, the way Phoenix's projection would.
 * Each test gets its own client, so one test's recorder can never be
 * written to by another's render.
 */
function useApi(seed: TrainingAnnouncementOccurrence[]) {
	const windowItems = [...seed];
	let suppressions: TrainingAnnouncementSuppression[] = [];
	let overridesList: TrainingAnnouncementOverride[] = [];
	const calls: Call[] = [];
	configureClient({ baseUrl: "/api", credentials: "include", retry: 0 });

	getClient().setConfig({
		kyOptions: {
			fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
				const request =
					input instanceof Request ? input : new Request(input, init);
				const url = request.url;
				const method = request.method.toUpperCase();
				let body: StubBody | undefined;
				if (method !== "GET" && method !== "HEAD") {
					try {
						// SAFETY: the generated client validates every write body
						// against its request schema before this fetch runs, so
						// parsed JSON is the exception request shape this stub
						// records.
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

				if (method === "POST" && url.includes("/suppressions")) {
					// SAFETY: the stub answers a created suppression by echoing
					// the validated request body over the single-date defaults,
					// so the from and to dates are the request's by
					// construction.
					const created = suppression({ ...body });
					suppressions = [...suppressions, created];
					const at = windowItems.findIndex(
						(item) =>
							item.date === created.fromDate && item.subject === "occurrence",
					);
					if (at !== -1) {
						// SAFETY: the findIndex above guarantees an entry at
						// this index, so the access is the matched occurrence.
						const current = windowItems[at] as TrainingAnnouncementOccurrence;
						windowItems[at] = {
							...current,
							outcome: "skipped_suppressed",
							chain: ["holiday", "disablement", "suppression"],
							decidedBy: "suppression",
							appliedSuppressionId: created.id,
						};
					}
					return json({ data: created }, 201);
				}
				if (method === "POST" && url.includes("/overrides")) {
					// SAFETY: as above, the echoed request body is the
					// validated override shape, so the partial is complete
					// once the stub stamps its id.
					const created = override({ ...body });
					overridesList = [...overridesList, created];
					return json({ data: created }, 201);
				}
				if (method === "GET" && url.includes("/training-announcements")) {
					if (url.includes("/suppressions"))
						return json({ data: suppressions });
					if (url.includes("/overrides")) return json({ data: overridesList });
					if (url.includes("/occurrences/window")) {
						// Production latency, exaggerated: event-calendar measures
						// chip heights when the events arrive, so answering
						// synchronously would measure unstyled chips and hide them
						// behind "+N more".
						await new Promise((resolve) => setTimeout(resolve, 800));
						// Like Phoenix: only the inclusive [from, to] Dublin dates.
						const params = new URL(url).searchParams;
						const from = params.get("from") ?? "";
						const to = params.get("to") ?? "";
						return json({
							data: windowItems.filter(
								(item) => item.date >= from && item.date <= to,
							),
						});
					}
					if (url.includes("/occurrences")) {
						const direction = new URL(url).searchParams.get("direction");
						if (direction === "recent")
							return json({
								data: windowItems.filter((item) => item.delivery !== null),
							});
						return json({
							data: windowItems.filter((item) => item.delivery === null),
						});
					}
					return json({ data: [announcement()] });
				}
				return json({ errors: { detail: `${method} ${url}` } }, 404);
			},
		},
	});

	return { calls };
}

function defaultSeed(): TrainingAnnouncementOccurrence[] {
	return [occurrence(), deliveredPast(), inFlight(), holidayItem()];
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

function inspector(screen: Awaited<ReturnType<typeof renderRail>>) {
	return screen.getByTestId("occurrence-inspector");
}

async function openInspector(
	screen: Awaited<ReturnType<typeof renderRail>>,
	chip: string,
) {
	await screen.getByTestId("training-calendar").getByText(chip).first().click();
	await expect.element(inspector(screen)).toBeVisible();
}

test("scheduled posts show the preview without a posting checklist", async () => {
	useApi(defaultSeed());
	const screen = await renderRail();
	await openInspector(screen, "Roll call Thursday 8 October 2026");

	const dialog = inspector(screen);
	await expect
		.element(dialog.getByTestId("precedence-chain"))
		.not.toBeInTheDocument();
	await expect
		.element(dialog.getByText("Posting rules"))
		.not.toBeInTheDocument();
	await expect
		.element(dialog.getByTestId("not-sent-reason"))
		.not.toBeInTheDocument();

	// The Discord-rendered message and thread name, including @everyone.
	await expect.element(dialog.getByText("@everyone").first()).toBeVisible();
	await expect
		.element(dialog.getByText("Roll call Thursday 8 October 2026").first())
		.toBeVisible();

	// A future occurrence offers both per-date actions.
	await expect
		.element(dialog.getByRole("button", { name: "Skip this date" }))
		.toBeVisible();
	await expect
		.element(dialog.getByRole("button", { name: "Change text for this date" }))
		.toBeVisible();
});

// The exhaustive outcome → reason mapping lives in
// `lib/training-announcements/inspector.test.ts`; one outcome proves the render.
test.each([["skipped_suppressed", "Skipped for this date."]] as const)(
	"%s shows only the reason, not an unsent preview",
	async (outcome, reason) => {
		useApi([occurrence({ outcome })]);
		const screen = await renderRail();
		await openInspector(screen, "Roll call Thursday 8 October 2026");
		const dialog = inspector(screen);
		await expect
			.element(dialog.getByTestId("not-sent-reason"))
			.toHaveTextContent(reason);
		await expect
			.element(dialog.getByTestId("inspector-message"))
			.not.toBeInTheDocument();
		await expect
			.element(dialog.getByTestId("precedence-chain"))
			.not.toBeInTheDocument();
	},
);

test("past items show evidence with permalink and applied exception", async () => {
	useApi(defaultSeed());
	const screen = await renderRail();
	await openInspector(screen, "Special copy Tuesday 29 September 2026");

	const past = inspector(screen);
	await expect.element(past.getByTestId("delivery-evidence")).toBeVisible();
	await expect.element(past.getByText("posted").first()).toBeVisible();
	await expect
		.element(past.getByRole("link", { name: "Open in Discord" }))
		.toHaveAttribute(
			"href",
			"https://discord.com/channels/1/2/234567890123456789",
		);
	await expect
		.element(past.getByTestId("applied-override"))
		.toHaveTextContent(OVERRIDE_ID);
	await expect.element(past.getByText("Message posted")).toBeVisible();
});

test("in-flight items read posting", async () => {
	useApi(defaultSeed());
	const screen = await renderRail();
	await openInspector(screen, "Roll call Thursday 1 October 2026");
	const posting = inspector(screen);
	await expect.element(posting.getByText("posting…").first()).toBeVisible();
	await expect.element(posting.getByTestId("delivery-inflight")).toBeVisible();
});

test("skip-this-date creates a suppression and the calendar chip updates to skipped", async () => {
	const api = useApi(defaultSeed());
	const screen = await renderRail();
	await openInspector(screen, "Roll call Thursday 8 October 2026");

	await inspector(screen)
		.getByRole("button", { name: "Skip this date" })
		.click();
	const sheet = screen.getByTestId("suppression-sheet");
	await expect.element(sheet).toBeVisible();
	// The form arrives pre-filled for the occurrence's date. The picker renders
	// the resolved Dublin day, not an `YYYY-MM-DD` input value.
	await expect
		.element(sheet.getByLabelText("First date"))
		.toHaveTextContent("October 8, 2026");

	await sheet.getByRole("button", { name: "Skip these dates" }).click();
	await expect
		.poll(() =>
			api.calls.some(
				(call) => call.method === "POST" && call.url.includes("/suppressions"),
			),
		)
		.toBe(true);
	const post = api.calls.find(
		(call) => call.method === "POST" && call.url.includes("/suppressions"),
	);
	expect(post?.body).toMatchObject({
		fromDate: "2026-10-08",
		toDate: "2026-10-08",
	});

	// The window refetch re-resolves the chip: scheduled becomes skipped.
	const calendar = screen.getByTestId("training-calendar");
	await expect.element(calendar.getByText("skipped").first()).toBeVisible();
});

test("change-copy opens the override form pre-filled for that date", async () => {
	const api = useApi(defaultSeed());
	const screen = await renderRail();
	await openInspector(screen, "Roll call Thursday 8 October 2026");

	await inspector(screen)
		.getByRole("button", { name: "Change text for this date" })
		.click();
	const sheet = screen.getByTestId("override-sheet");
	await expect.element(sheet).toBeVisible();
	await expect
		.element(sheet.getByLabelText("First date"))
		.toHaveTextContent("October 8, 2026");
	await expect
		.element(sheet.getByLabelText("Last date, inclusive"))
		.toHaveTextContent("October 8, 2026");
	// The copy arrives pre-filled with what the date currently resolves
	// to, so editing starts from the members' view rather than a blank
	// field. The `{{date}}` token reads as its `Date` chip.
	await expect
		.element(sheet.getByRole("textbox", { name: "Title", exact: true }))
		.toHaveTextContent("Roll call Date");
	await expect
		.element(sheet.getByRole("textbox", { name: "Message", exact: true }))
		.toHaveTextContent("Who is coming?");

	await sheet
		.getByRole("textbox", { name: "Title", exact: true })
		.fill("Halloween special");
	await sheet.getByRole("button", { name: "Change text", exact: true }).click();
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
		toDate: "2026-10-08",
		title: "Halloween special",
		message: "Who is coming?",
	});
});

test("holiday items open read-only with no actions", async () => {
	useApi(defaultSeed());
	const screen = await renderRail();
	await openInspector(screen, "No training Monday 26 October 2026");

	const dialog = inspector(screen);
	await expect
		.element(dialog.getByTestId("precedence-chain"))
		.not.toBeInTheDocument();
	await expect
		.element(dialog.getByText("No training — bank holiday"))
		.toBeVisible();
	await expect
		.element(dialog.getByText(/cannot be edited or skipped/))
		.toBeVisible();
	await expect
		.element(dialog.getByRole("button", { name: "Skip this date" }))
		.not.toBeInTheDocument();
	await expect
		.element(dialog.getByRole("button", { name: "Change text for this date" }))
		.not.toBeInTheDocument();
});
