/**
 * Editor wiring for the Training Announcement save machine (ALE-448): the
 * sheet sends its draft, renders the machine's stage-scoped states, and stops
 * the machine when it closes. The ordering rules themselves are asserted in
 * `save-machine.test.ts`; these tests check the real sheet reaches them.
 */
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
const ID = "11111111-1111-1111-1111-111111111111";

const ROW: TrainingAnnouncement = {
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
};

type Answer = {
	status: number;
	body: { errors: { detail: string; fields: Record<string, string[]> } };
};
type Write = "schedule" | "copy";
/** Every body this in-memory Phoenix answers with. */
type Payload =
	| Answer["body"]
	| { errors: { detail: string } }
	| {
			data:
				| TrainingAnnouncement
				| TrainingAnnouncement[]
				| { announcement: TrainingAnnouncement; warnings: string[] };
	  };

/**
 * An in-memory Phoenix for one announcement. `answers` scripts the next
 * replies per write (default: accept); `hold` parks a write until released.
 */
function useApi(
	script: {
		answers?: Partial<Record<Write, Answer[]>>;
		hold?: Write;
		warnings?: string[];
	} = {},
) {
	let row = { ...ROW };
	const writes: { write: Write; body: unknown }[] = [];
	let release: (() => void) | undefined;
	configureClient({ baseUrl: "/api", credentials: "include", retry: 0 });
	getClient().setConfig({
		kyOptions: {
			fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
				const request =
					input instanceof Request ? input : new Request(input, init);
				const { url } = request;
				const method = request.method.toUpperCase();
				const json = (payload: Payload, status = 200) =>
					new Response(JSON.stringify(payload), {
						status,
						headers: { "content-type": "application/json" },
					});

				if (method === "GET" && url.includes("/occurrences"))
					return json({ data: [] });
				if (method === "GET") return json({ data: [row] });

				const write: Write | undefined = url.endsWith("/schedule")
					? "schedule"
					: url.endsWith("/copy")
						? "copy"
						: undefined;
				if (method !== "PUT" || !write)
					return json({ errors: { detail: `${method} ${url}` } }, 404);

				// SAFETY: the generated client validated this body against the
				// write's request schema before sending it.
				const body = (await request
					.clone()
					.json()) as Partial<TrainingAnnouncement>;
				writes.push({ write, body });
				if (script.hold === write) {
					await new Promise<void>((resolve) => {
						release = resolve;
					});
				}
				const scripted = script.answers?.[write]?.shift();
				if (scripted) return json(scripted.body, scripted.status);

				row = { ...row, ...body };
				// Phoenix stores the `HH:MM` it was sent as `HH:MM:SS`.
				if (body.postTime) row.postTime = `${body.postTime}:00`;
				return write === "schedule"
					? json({
							data: { announcement: row, warnings: script.warnings ?? [] },
						})
					: json({ data: row });
			},
		},
	});
	return {
		writes,
		order: () => writes.map((entry) => entry.write),
		release: () => release?.(),
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

function gone(locator: Locator): boolean {
	return locator.query() === null;
}

const refused = (detail: string, fields: Record<string, string[]>) => ({
	status: 422,
	body: { errors: { detail, fields } },
});

async function openEditor(screen: Awaited<ReturnType<typeof renderRail>>) {
	await screen.getByRole("button", { name: /^Edit Roll call/ }).click();
	await expect.element(screen.getByTestId("announcement-sheet")).toBeVisible();
}

test("a schedule edit saves the schedule, then the copy, and reports its warnings", async () => {
	const api = useApi({ warnings: ["slot_collision"] });
	const screen = await renderRail();
	await openEditor(screen);

	await screen.getByLabelText("Post time").fill("11:00");
	await screen.getByRole("textbox", { name: "Title" }).fill("Roll call soon");
	await screen.getByRole("button", { name: "Save changes" }).click();

	await expect
		.poll(() => gone(screen.getByTestId("announcement-sheet")))
		.toBe(true);
	expect(api.order()).toEqual(["schedule", "copy"]);
	expect(api.writes[0]?.body).toEqual({
		weekday: 4,
		oneOffDate: null,
		postTime: "11:00",
	});
	expect(api.writes[1]?.body).toMatchObject({ title: "Roll call soon" });
	await expect
		.element(screen.getByTestId("announcement-warning"))
		.toHaveTextContent(/Another announcement is scheduled/);
});

test("a copy-only edit sends only the copy and shows no warnings", async () => {
	const api = useApi({ warnings: ["slot_collision"] });
	const screen = await renderRail();
	await openEditor(screen);

	await screen.getByRole("textbox", { name: "Title" }).fill("Only the copy");
	await screen.getByRole("button", { name: "Save changes" }).click();

	await expect
		.poll(() => gone(screen.getByTestId("announcement-sheet")))
		.toBe(true);
	expect(api.order()).toEqual(["copy"]);
	expect(gone(screen.getByTestId("announcement-warning"))).toBe(true);
});

test("a schedule refusal shows on the post time and never writes the copy", async () => {
	const api = useApi({
		answers: {
			schedule: [
				refused("postTime: the first send instant has elapsed", {
					postTime: ["the first send instant has elapsed"],
				}),
			],
		},
	});
	const screen = await renderRail();
	await openEditor(screen);

	await screen.getByLabelText("Post time").fill("08:00");
	await screen.getByRole("button", { name: "Save changes" }).click();

	await expect
		.element(screen.getByText("the first send instant has elapsed").first())
		.toBeVisible();
	await expect
		.element(screen.getByLabelText("Post time"))
		.toHaveAttribute("aria-invalid", "true");
	expect(api.order()).toEqual(["schedule"]);
	await expect
		.element(screen.getByRole("button", { name: "Save changes" }))
		.toBeEnabled();
});

test("a copy refusal after a schedule write says the schedule landed, and retry writes only the copy", async () => {
	const api = useApi({
		answers: {
			copy: [
				refused("message: unknown placeholder", {
					message: ["unknown placeholder"],
				}),
			],
		},
	});
	const screen = await renderRail();
	await openEditor(screen);

	await screen.getByLabelText("Post time").fill("11:00");
	await screen.getByRole("button", { name: "Save changes" }).click();

	const error = screen.getByTestId("announcement-sheet-error");
	await expect
		.element(error)
		.toHaveTextContent(/new schedule was saved, but the message was not/);
	await expect.element(error).toHaveTextContent(/unknown placeholder/);
	expect(api.order()).toEqual(["schedule", "copy"]);

	await screen.getByRole("button", { name: "Save changes" }).click();
	await expect
		.poll(() => gone(screen.getByTestId("announcement-sheet")))
		.toBe(true);
	expect(api.order()).toEqual(["schedule", "copy", "copy"]);
});

test("the save button is busy while a stage is in flight", async () => {
	const api = useApi({ hold: "copy" });
	const screen = await renderRail();
	await openEditor(screen);

	await screen.getByRole("textbox", { name: "Title" }).fill("Slow");
	await screen.getByRole("button", { name: "Save changes" }).click();
	await expect
		.element(screen.getByRole("button", { name: "Saving…" }))
		.toBeDisabled();
	await expect.poll(() => api.order()).toEqual(["copy"]);

	api.release();
	await expect
		.poll(() => gone(screen.getByTestId("announcement-sheet")))
		.toBe(true);
});

test("a save that answers after its sheet closed cannot close the next sheet", async () => {
	const api = useApi({ hold: "copy" });
	const screen = await renderRail();
	await openEditor(screen);

	await screen.getByRole("textbox", { name: "Title" }).fill("Abandoned");
	await screen.getByRole("button", { name: "Save changes" }).click();
	await expect.poll(() => api.order()).toEqual(["copy"]);
	await screen.getByRole("button", { name: "Cancel" }).click();
	await expect
		.poll(() => gone(screen.getByTestId("announcement-sheet")))
		.toBe(true);

	await screen
		.getByRole("button", { name: "New announcement" })
		.first()
		.click();
	await expect
		.element(screen.getByRole("button", { name: "Create announcement" }))
		.toBeVisible();

	api.release();
	// The abandoned write still lands, and the list reconciles to it…
	await expect
		.element(screen.getByText("Abandoned", { exact: true }))
		.toBeVisible();
	// …but the replacement sheet stays open.
	await expect
		.element(screen.getByRole("button", { name: "Create announcement" }))
		.toBeVisible();
});
