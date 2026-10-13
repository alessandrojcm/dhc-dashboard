import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { render } from "vitest-browser-svelte";
import { userEvent } from "vitest/browser";
import { onHostTimeZone } from "#lib/testing/host-time-zone.js";
import WorkshopForm from "./workshop-form.svelte";

// Eight hours behind Dublin (seven across late October), so a form that read
// or wrote the organiser's own zone would show it.
onHostTimeZone("America/Los_Angeles");

type Submission = { workshopDate: string; workshopEndDate: string };

/**
 * Records what the form submits: its own form data at the moment it is
 * submitted, once the remote form has actually sent the request. The request
 * itself is answered locally, so nothing leaves the browser.
 */
function recordSubmissions() {
	const submissions: Submission[] = [];
	let requests = 0;
	const realFetch = globalThis.fetch;

	const onSubmit = (event: SubmitEvent) => {
		if (!(event.target instanceof HTMLFormElement)) return;
		const entries = [...new FormData(event.target)];
		const field = (name: string) => {
			const value = entries.find(([key]) =>
				new RegExp(`(^|:)${name}(/|$)`).test(key),
			)?.[1];
			return value instanceof File ? "" : (value ?? "");
		};
		submissions.push({
			workshopDate: field("workshop_date"),
			workshopEndDate: field("workshop_end_date"),
		});
	};

	beforeEach(() => {
		submissions.length = 0;
		requests = 0;
		document.addEventListener("submit", onSubmit, { capture: true });
		globalThis.fetch = async () => {
			requests += 1;
			return new Response(JSON.stringify({ type: "result", result: "{}" }), {
				headers: { "content-type": "application/json" },
			});
		};
	});

	afterEach(() => {
		document.removeEventListener("submit", onSubmit, { capture: true });
		globalThis.fetch = realFetch;
	});

	return {
		submissions,
		requests: () => requests,
	};
}

const recorded = recordSubmissions();

function renderForm(initialData?: { start: string; end: string }) {
	return render(WorkshopForm, {
		mode: initialData ? "edit" : "create",
		workshopStatus: initialData ? "planned" : undefined,
		initialData: {
			title: "Longsword basics",
			location: "Main hall",
			max_capacity: 12,
			...(initialData && {
				workshop_date: new Date(initialData.start),
				workshop_end_date: new Date(initialData.end),
			}),
		},
	});
}

type Screen = Awaited<ReturnType<typeof renderForm>>;

const from = (screen: Screen) =>
	screen.getByRole("textbox", { name: "From", exact: true });
const to = (screen: Screen) =>
	screen.getByRole("textbox", { name: "To", exact: true });

async function pickDate(
	screen: Screen,
	{ year, month, day }: { year: number; month: number; day: string },
) {
	await expect
		.element(screen.getByTestId("workshop-date-time-picker"))
		.toHaveAttribute("data-hydrated", "true");
	await screen.getByRole("button", { name: "Date", exact: true }).click();
	await userEvent.selectOptions(
		screen.getByLabelText("Select a year"),
		String(year),
	);
	await userEvent.selectOptions(
		screen.getByLabelText("Select a month"),
		String(month),
	);
	await screen.getByRole("button", { name: day }).click();
}

async function submit(screen: Screen, name: string) {
	await screen.getByRole("button", { name }).click();
	await expect.poll(() => recorded.requests()).toBe(1);
	expect(recorded.submissions).toHaveLength(1);
	return recorded.submissions[0];
}

describe("the workshop form on a host in Los Angeles", () => {
	it("submits the instant for 18:30 Dublin when 18:30 is entered", async () => {
		const screen = await renderForm();

		await pickDate(screen, {
			year: 2026,
			month: 10,
			day: "Tuesday, October 20, 2026",
		});
		await userEvent.fill(from(screen), "18:30");
		await userEvent.fill(to(screen), "20:30");

		// 18:30 IST is 17:30 UTC, and 10:30 in Los Angeles.
		expect(await submit(screen, "Create Workshop")).toEqual({
			workshopDate: "2026-10-20T17:30:00.000Z",
			workshopEndDate: "2026-10-20T19:30:00.000Z",
		});
	});

	it("starts a newly picked date at 10:00 and ends it at 12:00 Dublin", async () => {
		const screen = await renderForm();

		await pickDate(screen, {
			year: 2026,
			month: 12,
			day: "Saturday, December 5, 2026",
		});

		await expect.element(from(screen)).toHaveValue("10:00");
		await expect.element(to(screen)).toHaveValue("12:00");
		expect(await submit(screen, "Create Workshop")).toEqual({
			workshopDate: "2026-12-05T10:00:00.000Z",
			workshopEndDate: "2026-12-05T12:00:00.000Z",
		});
	});

	it("shows an existing workshop on the Dublin clock and keeps it when saved", async () => {
		// 18:30–20:30 Dublin on Tuesday 20 October; 10:30–12:30 in Los Angeles.
		const screen = await renderForm({
			start: "2026-10-20T17:30:00Z",
			end: "2026-10-20T19:30:00Z",
		});

		await expect.element(from(screen)).toHaveValue("18:30");
		await expect.element(to(screen)).toHaveValue("20:30");
		await expect
			.element(screen.getByRole("button", { name: "Date", exact: true }))
			.toHaveTextContent("Tue 20 Oct 2026");
		await expect.element(screen.getByText("18:30–20:30")).toBeVisible();

		expect(await submit(screen, "Update Workshop")).toEqual({
			workshopDate: "2026-10-20T17:30:00.000Z",
			workshopEndDate: "2026-10-20T19:30:00.000Z",
		});
	});

	it("shows a late-evening Dublin start on its Dublin day", async () => {
		// 23:30 IST on 14 July is 22:30 UTC; still 14 July in Los Angeles, but
		// the end, 00:30 IST, is the next Dublin day.
		const screen = await renderForm({
			start: "2026-07-14T22:30:00Z",
			end: "2026-07-14T23:30:00Z",
		});

		await expect.element(from(screen)).toHaveValue("23:30");
		await expect.element(to(screen)).toHaveValue("00:30");
		await expect
			.element(screen.getByRole("button", { name: "Date", exact: true }))
			.toHaveTextContent("Tue 14 Jul 2026");

		// The end keeps its own Dublin day when only its time changes.
		await userEvent.fill(to(screen), "01:00");
		expect(await submit(screen, "Update Workshop")).toEqual({
			workshopDate: "2026-07-14T22:30:00.000Z",
			workshopEndDate: "2026-07-15T00:00:00.000Z",
		});
	});

	it("moves a start the March clock change skips forward to Irish Summer Time", async () => {
		const screen = await renderForm();

		await pickDate(screen, {
			year: 2026,
			month: 3,
			day: "Sunday, March 29, 2026",
		});
		// 01:00–01:59 never happens in Dublin that night.
		await userEvent.fill(from(screen), "01:30");

		await expect.element(from(screen)).toHaveValue("02:30");
		expect(await submit(screen, "Create Workshop")).toMatchObject({
			workshopDate: "2026-03-29T01:30:00.000Z",
		});
	});

	it("reads a start the October clock change repeats as the summer one", async () => {
		const screen = await renderForm();

		await pickDate(screen, {
			year: 2026,
			month: 10,
			day: "Sunday, October 25, 2026",
		});
		// 01:30 happens twice that night: first in IST, then again in GMT.
		await userEvent.fill(from(screen), "01:30");

		await expect.element(from(screen)).toHaveValue("01:30");
		expect(await submit(screen, "Create Workshop")).toMatchObject({
			workshopDate: "2026-10-25T00:30:00.000Z",
			// The default end, 12:00 GMT, is after the change.
			workshopEndDate: "2026-10-25T12:00:00.000Z",
		});
	});
});
