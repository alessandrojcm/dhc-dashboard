import {
	configureClient,
	getClient,
	type TrainingAnnouncementOccurrence,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import TrainingCalendarTestWrapper from "./TrainingCalendar.test-wrapper.svelte";

const TODAY = "2026-10-01"; // a Thursday
const HORIZON = "2025-08-27"; // TODAY minus the 400-day retention
const ROLL_CALL_ID = "11111111-1111-1111-1111-111111111111";

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

const WINDOW_ITEMS: TrainingAnnouncementOccurrence[] = [
	occurrence(),
	occurrence({
		date: "2026-10-01",
		outcome: "post_override",
		chain: ["disablement", "suppression", "override"],
		decidedBy: "override",
		threadName: "Special sparring Thursday 1 October 2026",
		delivery: {
			id: "22222222-2222-2222-2222-222222222222",
			state: "thread_failed",
			reason: "timeout",
			frozenAt: "2026-10-01T09:59:00Z",
			postingStartedAt: "2026-10-01T10:00:00Z",
			messagePostedAt: "2026-10-01T10:00:05Z",
			threadCreatedAt: null,
			concludedAt: "2026-10-01T10:01:00Z",
			discordMessageId: "234567890123456789",
			discordThreadId: null,
			permalink: "https://discord.com/channels/1/2/234567890123456789",
			errorDetail: "Thread timeout",
			threadAttempts: 3,
			lastThreadError: "Thread timeout",
			appliedSuppressionId: null,
			appliedOverrideId: null,
		},
	}),
	occurrence({
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
	}),
];

type Call = { method: string; url: string };

/** Every body the in-memory Phoenix can answer the occurrence reads with. */
type StubPayload = { data: TrainingAnnouncementOccurrence[] };

/**
 * Points the generated client at an in-memory Phoenix serving the occurrence
 * read model. `window` answers the fixture items; every other read answers
 * empty. Each test gets its own client, so one test's recorder can never be
 * written to by another's render.
 */
function useApi() {
	const calls: Call[] = [];
	configureClient({ baseUrl: "/api", credentials: "include", retry: 0 });

	getClient().setConfig({
		kyOptions: {
			fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
				const request =
					input instanceof Request ? input : new Request(input, init);
				calls.push({ method: request.method.toUpperCase(), url: request.url });

				// Production latency, exaggerated: event-calendar measures chip
				// heights when the events arrive, so answering synchronously
				// would measure unstyled chips and hide them behind "+N more".
				// The delay lets the test iframe's stylesheets land first, the
				// way a real network round-trip always does.
				await new Promise((resolve) => setTimeout(resolve, 800));

				const json = (payload: StubPayload, status = 200) =>
					new Response(JSON.stringify(payload), {
						status,
						headers: { "content-type": "application/json" },
					});

				if (request.url.includes("/occurrences/window")) {
					// Like Phoenix: only the inclusive [from, to] Dublin dates.
					const params = new URL(request.url).searchParams;
					const from = params.get("from") ?? "";
					const to = params.get("to") ?? "";
					return json({
						data: WINDOW_ITEMS.filter(
							(item) => item.date >= from && item.date <= to,
						),
					});
				}
				return json({ data: [] });
			},
		},
	});

	return { calls };
}

function windowCalls(calls: Call[]): string[] {
	return calls
		.filter((call) => call.url.includes("/occurrences/window"))
		.map((call) => call.url);
}

function renderCalendar(initialDate?: string) {
	const queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false, staleTime: Infinity, refetchOnMount: false },
			mutations: { retry: false },
		},
	});
	return render(TrainingCalendarTestWrapper, {
		today: TODAY,
		initialDate,
		queryClient,
	});
}

test("month view lists occurrences and holiday items from the window", async () => {
	const api = useApi();
	const screen = await renderCalendar();

	// Each chip shows the resolved title Phoenix computed, never a template.
	await expect
		.element(screen.getByText("Roll call Thursday 8 October 2026").first())
		.toBeVisible();
	await expect
		.element(
			screen.getByText("Special sparring Thursday 1 October 2026").first(),
		)
		.toBeVisible();

	// Grouped display statuses: a thread failure still reached members.
	await expect.element(screen.getByText("scheduled").first()).toBeVisible();
	await expect
		.element(screen.getByText("posted, no thread").first())
		.toBeVisible();

	// The holiday announcement is a read-only item on a striped bank-holiday day.
	await expect
		.element(screen.getByText("No training Monday 26 October 2026").first())
		.toBeVisible();
	await expect.element(screen.getByText("read-only").first()).toBeVisible();
	expect(screen.container.querySelector(".ta-holiday-day")).not.toBeNull();

	// The visible grid drives one window read with inclusive Dublin bounds.
	expect(windowCalls(api.calls)).toHaveLength(1);
	expect(windowCalls(api.calls)[0]).toContain("from=2026-09-28");
});

test("week view renders the same posts without refetch loops", async () => {
	const api = useApi();
	const screen = await renderCalendar();

	await expect
		.element(screen.getByText("Roll call Thursday 8 October 2026").first())
		.toBeVisible();
	expect(windowCalls(api.calls)).toHaveLength(1);

	await screen.getByRole("button", { name: "Week" }).click();

	// The week asks for its own (narrower) range exactly once, and shows only
	// the posts whose send date falls inside it.
	await expect
		.element(
			screen.getByText("Special sparring Thursday 1 October 2026").first(),
		)
		.toBeVisible();
	expect(windowCalls(api.calls)).toHaveLength(2);
	expect(windowCalls(api.calls)[1]).toContain("from=2026-09-28");
	expect(windowCalls(api.calls)[1]).toContain("to=2026-10-04");

	await screen.getByRole("button", { name: "Month" }).click();
	await expect
		.element(screen.getByText("Roll call Thursday 8 October 2026").first())
		.toBeVisible();
	// …and returning to a seen range serves the cache instead of refetching.
	expect(windowCalls(api.calls)).toHaveLength(2);

	// A re-render loop would keep fetching; stillness proves the datesSet guard.
	await new Promise((resolve) => setTimeout(resolve, 750));
	expect(windowCalls(api.calls)).toHaveLength(2);
});

test("navigation before the retention horizon is refused without calling the api", async () => {
	const api = useApi();
	// September 2025 opens on Monday the 1st, inside the horizon.
	const screen = await renderCalendar("2025-09-15");

	await expect
		.element(screen.getByText("September 2025").first())
		.toBeVisible();
	expect(windowCalls(api.calls)).toHaveLength(1);

	// One step back starts late July, before the horizon — refused with an
	// explanation instead of empty or recomputed history.
	const prev = screen.container.querySelector(".ec-prev");
	expect(prev).not.toBeNull();
	// SAFETY: asserted non-null above; the toolbar always renders prev/next.
	(prev as HTMLElement).click();
	await expect
		.element(screen.getByText(/History before .* is not kept/))
		.toBeVisible();

	for (const url of windowCalls(api.calls)) {
		expect(url).not.toMatch(/from=2025-0[78]-/);
		const from = new URL(url).searchParams.get("from") ?? "";
		expect(from >= HORIZON).toBe(true);
	}

	// Back to today recovers the calendar.
	await screen.getByRole("button", { name: "Back to today" }).click();
	await expect
		.element(screen.getByText("Roll call Thursday 8 October 2026").first())
		.toBeVisible();
});
