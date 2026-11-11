import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { render } from "vitest-browser-svelte";
import { userEvent } from "vitest/browser";
import { onHostTimeZone } from "#lib/testing/host-time-zone.js";
import WorkshopForm from "./workshop-form.svelte";
import {
	FakeVenueLookup,
	venueLookupContext,
} from "#lib/testing/fake-venue-lookup.js";

// ALE-442: the one venue lookup boundary is substituted with a synthetic
// catalogue; no request reaches Phoenix or Google.
const hall = {
	provider: "google" as const,
	placeId: "place_hall",
	name: "Synthetic Fencing Hall",
	address: "1 Example Street, Dublin 8",
	attributions: [
		{ provider: "Venue Guide", providerUri: "https://guide.example.test/" },
	],
};
const annex = {
	provider: "google" as const,
	placeId: "place_annex",
	name: "Synthetic Fencing Annex",
	address: "2 Example Street, Dublin 8",
	attributions: [],
};
let lookup = new FakeVenueLookup([annex, hall]);
beforeEach(() => {
	lookup = new FakeVenueLookup([annex, hall]);
});

// Eight hours behind Dublin (seven across late October), so a form that read
// or wrote the organiser's own zone would show it.
onHostTimeZone("America/Los_Angeles");

type Submission = {
	workshopDate: string;
	workshopEndDate: string;
	destinationText: string;
	destinationPlaceId: string;
	/** Present only if the form (wrongly) submitted Google's credits. */
	destinationAttributions: string;
};

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
			destinationText: field("destination_text"),
			destinationPlaceId: field("destination_place_id"),
			destinationAttributions: field("destination_attributions"),
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

function renderForm(initialData?: {
	start: string;
	end: string;
	destination_text?: string;
	destination_place_id?: string;
}) {
	return render(WorkshopForm, {
		context: venueLookupContext(lookup),
		props: {
			mode: initialData ? "edit" : "create",
			workshopStatus: initialData ? "planned" : undefined,
			initialData: {
				title: "Longsword basics",
				location: "Main hall",
				max_capacity: 12,
				...(initialData && {
					workshop_date: new Date(initialData.start),
					workshop_end_date: new Date(initialData.end),
					destination_text: initialData.destination_text ?? "",
					destination_place_id: initialData.destination_place_id ?? "",
				}),
			},
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
		expect(await submit(screen, "Create Workshop")).toMatchObject({
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
		expect(await submit(screen, "Create Workshop")).toMatchObject({
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

		expect(await submit(screen, "Update Workshop")).toMatchObject({
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
		expect(await submit(screen, "Update Workshop")).toMatchObject({
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

// ALE-440/ALE-442: one autocomplete input. Typed text is saved exactly as
// written unless a suggestion is deliberately chosen, which saves only its
// Place ID.
describe("the workshop form's destination input", () => {
	// A complete edit form (title, label, dates, capacity, price all
	// prefilled) so a submission passes the form's client-side preflight and
	// the destination is what varies.
	const completeEditForm = (
		extra: { destination_text?: string; destination_place_id?: string } = {},
	) =>
		renderForm({
			start: "2026-10-20T17:30:00Z",
			end: "2026-10-20T19:30:00Z",
			...extra,
		});

	const destination = (screen: Screen) =>
		screen.getByRole("combobox", { name: "Destination", exact: true });

	it("is the only destination control: no separate name, address or link inputs", async () => {
		const screen = await completeEditForm();

		await expect.element(destination(screen)).toBeVisible();
		for (const name of [
			"Destination name",
			"Destination address",
			"Google Maps directions link",
		])
			expect(screen.getByRole("textbox", { name }).elements()).toHaveLength(0);
	});

	it("saves typed text exactly as written when no suggestion is chosen", async () => {
		const screen = await completeEditForm();

		await userEvent.click(destination(screen));
		await userEvent.keyboard("Synthetic Fencing");
		await expect.element(screen.getByRole("option").first()).toBeVisible();
		// Moving on without choosing keeps the text, not a suggestion.
		await userEvent.keyboard("{Escape}");
		await expect
			.element(screen.getByRole("option").first())
			.not.toBeInTheDocument();

		expect(lookup.resolveCalls).toEqual([]);
		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationText: "Synthetic Fencing",
			destinationPlaceId: "",
			destinationAttributions: "",
		});
	});

	it("submits an empty destination when none is entered", async () => {
		const screen = await completeEditForm();

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationText: "",
			destinationPlaceId: "",
		});
	});

	it("prefills saved manual text on edit and resubmits it unchanged", async () => {
		const screen = await completeEditForm({
			destination_text: "National Basketball Arena, Tymon Park, Dublin 6w",
		});

		await expect
			.element(destination(screen))
			.toHaveValue("National Basketball Arena, Tymon Park, Dublin 6w");
		// An unrelated edit resubmits the stored destination untouched, and
		// showing saved text never searches.
		await userEvent.fill(
			screen.getByRole("textbox", { name: "Workshop title", exact: true }),
			"Renamed workshop",
		);
		expect(lookup.suggestCalls).toEqual([]);
		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationText: "National Basketball Arena, Tymon Park, Dublin 6w",
			destinationPlaceId: "",
		});
	});

	it("chooses a suggestion by keyboard without submitting, shows its text with attribution, then saves only its ID", async () => {
		const screen = await completeEditForm({ destination_text: "Our hall" });

		await userEvent.fill(destination(screen), "");
		await userEvent.click(destination(screen));
		await userEvent.keyboard("Synthetic");
		await expect.element(screen.getByRole("option").first()).toBeVisible();
		await expect
			.element(screen.getByText("2 places found", { exact: false }))
			.toBeInTheDocument();
		// Nothing is chosen until the person chooses it.
		expect(lookup.resolveCalls).toEqual([]);
		await expect
			.element(destination(screen))
			.not.toHaveAttribute("aria-activedescendant");

		await userEvent.keyboard("{ArrowDown}{ArrowDown}{Enter}");

		await expect
			.element(destination(screen))
			.toHaveValue("Synthetic Fencing Hall, 1 Example Street, Dublin 8");
		const attribution = screen.getByTestId("destination-attribution").last();
		await expect.element(attribution).toHaveTextContent("Google Maps");
		await expect
			.element(attribution.getByRole("link", { name: "Venue Guide" }))
			.toHaveAttribute("referrerpolicy", "no-referrer");
		// The choice resolves in the same session the search used.
		expect(lookup.resolveCalls).toEqual([
			{
				placeId: "place_hall",
				sessionToken: lookup.suggestCalls.at(-1)?.sessionToken,
			},
		]);
		expect(recorded.requests()).toBe(0);

		// Google's text is never submitted: only the Place ID.
		expect(await submit(screen, "Update Workshop")).toEqual({
			workshopDate: expect.any(String),
			workshopEndDate: expect.any(String),
			destinationText: "",
			destinationPlaceId: "place_hall",
			destinationAttributions: "",
		});
	});

	it("chooses a suggestion by pointer", async () => {
		const screen = await completeEditForm();

		await userEvent.click(destination(screen));
		await userEvent.keyboard("Annex");
		await screen.getByRole("option", { name: /Annex/ }).click();
		await expect
			.element(destination(screen))
			.toHaveValue("Synthetic Fencing Annex, 2 Example Street, Dublin 8");

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationText: "",
			destinationPlaceId: "place_annex",
		});
	});

	it("typing again after a choice discards it and saves the new text", async () => {
		const screen = await completeEditForm();

		await userEvent.click(destination(screen));
		await userEvent.keyboard("Annex");
		await screen.getByRole("option", { name: /Annex/ }).click();
		await expect
			.element(destination(screen))
			.toHaveValue("Synthetic Fencing Annex, 2 Example Street, Dublin 8");

		await userEvent.keyboard(", back door");
		await userEvent.keyboard("{Escape}");
		expect(
			screen.getByTestId("destination-attribution").elements(),
		).toHaveLength(0);

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationText:
				"Synthetic Fencing Annex, 2 Example Street, Dublin 8, back door",
			destinationPlaceId: "",
		});
	});

	it("the clear button empties the input and any selection", async () => {
		const screen = await completeEditForm();

		await userEvent.click(destination(screen));
		await userEvent.keyboard("Synthetic");
		await expect.element(screen.getByRole("option").first()).toBeVisible();
		await userEvent.keyboard("{ArrowDown}{Enter}");
		await expect
			.element(destination(screen))
			.toHaveValue("Synthetic Fencing Annex, 2 Example Street, Dublin 8");

		await screen.getByRole("button", { name: "Clear destination" }).click();
		await expect.element(destination(screen)).toHaveValue("");
		await expect.element(destination(screen)).toHaveFocus();
		expect(screen.getByText("Synthetic Fencing Annex").elements()).toHaveLength(
			0,
		);

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationText: "",
			destinationPlaceId: "",
			destinationAttributions: "",
		});
	});

	it("saves typed text when Google is unavailable or not set up", async () => {
		lookup.suggestFailure =
			"Google venue search isn't set up; type the destination and it is saved as written";
		const screen = await completeEditForm();

		await userEvent.click(destination(screen));
		await userEvent.keyboard("Typed while Google is down");
		await expect
			.element(screen.getByRole("status").filter({ hasText: "isn't set up" }))
			.toBeVisible();

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationText: "Typed while Google is down",
			destinationPlaceId: "",
		});
	});

	it("says when nothing matches, and the typed text still saves", async () => {
		const screen = await completeEditForm();

		await userEvent.click(destination(screen));
		await userEvent.keyboard("Nowhere");
		await expect
			.element(screen.getByText("No places found", { exact: false }))
			.toBeVisible();

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationText: "Nowhere",
			destinationPlaceId: "",
		});
	});

	it("reopens a saved place without Google text and keeps it on an unrelated edit", async () => {
		const screen = await completeEditForm({
			destination_place_id: "place_hall",
		});

		await expect.element(destination(screen)).toHaveValue("");
		await expect
			.element(destination(screen))
			.toHaveAttribute("placeholder", "Google Maps place selected");
		await expect
			.element(screen.getByRole("status").filter({ hasText: "place selected" }))
			.toBeVisible();
		// No stored Google text and no fresh Details lookup.
		expect(lookup.resolveCalls).toEqual([]);
		expect(
			screen.getByTestId("destination-attribution").elements(),
		).toHaveLength(0);
		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationText: "",
			destinationPlaceId: "place_hall",
		});
	});

	it("shows the attendee preview: the label plus text, or Get directions for a place", async () => {
		const screen = await completeEditForm({
			destination_text: "Arena, Dublin 6w",
		});
		await expect
			.element(screen.getByText("Arena, Dublin 6w").last())
			.toBeVisible();

		await userEvent.fill(destination(screen), "");
		await userEvent.click(destination(screen));
		await userEvent.keyboard("Annex");
		await screen.getByRole("option", { name: /Annex/ }).click();
		await expect
			.element(screen.getByText("Get directions", { exact: true }))
			.toBeVisible();
	});
});
