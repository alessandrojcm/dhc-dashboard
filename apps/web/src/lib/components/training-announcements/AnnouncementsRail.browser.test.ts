import {
	configureClient,
	getClient,
	type TrainingAnnouncement,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { expect, test } from "vitest";
import type { Locator } from "vitest/browser";
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
};

/** Every body the in-memory Phoenix can answer with. */
type StubPayload =
	| { data: TrainingAnnouncement | TrainingAnnouncement[] }
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
		preview = {
			renderedMessage: "@everyone\nRoll call Thursday 8 October 2026",
			threadName: "Roll call Thursday 8 October 2026",
		},
	} = script;
	let rows = seeded;
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

				if (reject) return json(reject.body, reject.status);

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

	return { calls, rows: () => rows };
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

test("creates a weekly roll call pre-filled with the kind's preset", async () => {
	const api = useApi({ rows: [] });
	const screen = await renderRail();

	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();

	// The kind's copy is pre-filled, so cutover needs no wording.
	await expect
		.element(screen.getByLabelText("Title"))
		.toHaveValue("Roll call {{date}}");
	await expect
		.element(screen.getByLabelText("Message"))
		.toHaveValue(
			"Hey! It's {{weekday}}! Who is coming to training tonight? ⚔️",
		);
	await expect
		.element(screen.getByRole("radio", { name: /^Roll call/ }))
		.toBeChecked();

	await screen.getByRole("button", { name: "Create announcement" }).click();

	await expect
		.poll(() => api.calls.some((call) => call.method === "POST"))
		.toBe(true);
	expect(callBody(api, "POST", "/training-announcements")).toEqual({
		kind: "roll_call",
		weekday: 5,
		oneOffDate: null,
		postTime: "10:00",
		title: "Roll call {{date}}",
		message: "Hey! It's {{weekday}}! Who is coming to training tonight? ⚔️",
		mentionEveryone: true,
	});
	await expect
		.element(screen.getByRole("heading", { name: "Roll call {{date}}" }))
		.toBeVisible();
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
	await screen.getByLabelText("Date", { exact: true }).fill("2026-10-09");
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
	await screen.getByRole("button", { name: "Preview copy" }).click();

	const preview = screen.getByRole("group", { name: "Discord preview" });
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
				message: "Hey! Who is down for sparring this {{weekday}}? ⚔️",
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
		.element(screen.getByText(/Another announcement already posts/))
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
	await expect.element(screen.getByText(/has already posted/)).toBeVisible();
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
