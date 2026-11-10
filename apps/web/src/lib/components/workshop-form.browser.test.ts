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
	destinationName: string;
	destinationAddress: string;
	directionsUrl: string;
	destinationPlaceId: string;
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
			destinationName: field("destination_name"),
			destinationAddress: field("destination_address"),
			directionsUrl: field("directions_url"),
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
	destination_name?: string;
	destination_address?: string;
	directions_url?: string;
	destination_place_id?: string;
	destination_attributions?: string;
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
					destination_name: initialData.destination_name ?? "",
					destination_address: initialData.destination_address ?? "",
					directions_url: initialData.directions_url ?? "",
					destination_place_id: initialData.destination_place_id ?? "",
					destination_attributions: initialData.destination_attributions ?? "",
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

describe("the workshop form's destination details", () => {
	const destinationControls = (screen: Screen) => ({
		name: screen.getByRole("textbox", {
			name: "Destination name",
			exact: true,
		}),
		address: screen.getByRole("textbox", {
			name: "Destination address",
			exact: true,
		}),
		link: screen.getByRole("textbox", {
			name: "Google Maps directions link",
			exact: true,
		}),
	});

	// A complete edit form (title, label, dates, capacity, price all
	// prefilled) so a submission passes the form's client-side preflight and
	// the destination fields are what varies.
	const completeEditForm = () =>
		renderForm({
			start: "2026-10-20T17:30:00Z",
			end: "2026-10-20T19:30:00Z",
		});

	it("submits manually entered destination details beside the label", async () => {
		const screen = await completeEditForm();
		const controls = destinationControls(screen);

		await userEvent.fill(controls.name, "National Basketball Arena");
		await userEvent.fill(controls.address, "Tymon Park, Dublin 6w");
		await userEvent.fill(controls.link, "https://maps.app.goo.gl/AbCdEf");

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationName: "National Basketball Arena",
			destinationAddress: "Tymon Park, Dublin 6w",
			directionsUrl: "https://maps.app.goo.gl/AbCdEf",
		});
	});

	it("submits empty destination fields when none are entered", async () => {
		const screen = await completeEditForm();

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationName: "",
			destinationAddress: "",
			directionsUrl: "",
		});
	});

	it("prefills a stored destination on edit and resubmits it unchanged", async () => {
		const screen = await renderForm({
			start: "2026-10-20T17:30:00Z",
			end: "2026-10-20T19:30:00Z",
			destination_name: "National Basketball Arena",
			destination_address: "Tymon Park, Dublin 6w",
			directions_url: "https://maps.app.goo.gl/AbCdEf",
		});
		const controls = destinationControls(screen);

		await expect
			.element(controls.name)
			.toHaveValue("National Basketball Arena");
		await expect.element(controls.address).toHaveValue("Tymon Park, Dublin 6w");
		await expect
			.element(controls.link)
			.toHaveValue("https://maps.app.goo.gl/AbCdEf");

		// An unrelated edit resubmits the stored destination untouched.
		await userEvent.fill(
			screen.getByRole("textbox", { name: "Workshop title", exact: true }),
			"Renamed workshop",
		);
		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationName: "National Basketball Arena",
			destinationAddress: "Tymon Park, Dublin 6w",
			directionsUrl: "https://maps.app.goo.gl/AbCdEf",
		});
	});

	it("an emptied destination field submits as a clear, not the stored value", async () => {
		const screen = await renderForm({
			start: "2026-10-20T17:30:00Z",
			end: "2026-10-20T19:30:00Z",
			destination_name: "National Basketball Arena",
			destination_address: "Tymon Park, Dublin 6w",
			directions_url: "https://maps.app.goo.gl/AbCdEf",
		});
		const controls = destinationControls(screen);

		await userEvent.fill(controls.link, "");
		await userEvent.fill(controls.address, "");

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationName: "National Basketball Arena",
			destinationAddress: "",
			directionsUrl: "",
		});
	});

	it("keeps entered destination values and shows the field issue when the link is not https", async () => {
		const screen = await completeEditForm();
		const controls = destinationControls(screen);

		await userEvent.fill(controls.name, "Arena");
		await userEvent.fill(
			controls.link,
			"http://www.google.com/maps?q=Tallaght",
		);

		await screen.getByRole("button", { name: "Update Workshop" }).click();

		// No request leaves the browser: the form's own validation refused it.
		await expect
			.element(screen.getByText("Directions link must be an https link"))
			.toBeVisible();
		expect(recorded.requests()).toBe(0);
		await expect.element(controls.name).toHaveValue("Arena");
		await expect
			.element(controls.link)
			.toHaveValue("http://www.google.com/maps?q=Tallaght");
	});
});

describe("the workshop form's Google venue search (ALE-442)", () => {
	const completeEditForm = (extra = {}) =>
		renderForm({
			start: "2026-10-20T17:30:00Z",
			end: "2026-10-20T19:30:00Z",
			...extra,
		});

	const searchBox = (screen: Screen) =>
		screen.getByRole("combobox", { name: "Search Google Maps" });

	it("chooses a place by keyboard without submitting, previews it with attribution, then saves it", async () => {
		const screen = await completeEditForm({
			directions_url: "https://maps.app.goo.gl/Stale",
		});

		await userEvent.click(searchBox(screen));
		await userEvent.keyboard("Synthetic");
		await expect.element(screen.getByRole("option").first()).toBeVisible();
		await expect
			.element(screen.getByText("2 places found", { exact: false }))
			.toBeInTheDocument();
		// Nothing is chosen until the person chooses it.
		expect(lookup.resolveCalls).toEqual([]);
		await expect
			.element(searchBox(screen))
			.not.toHaveAttribute("aria-activedescendant");

		await userEvent.keyboard("{ArrowDown}{ArrowDown}{Enter}");

		const preview = screen.getByRole("region", {
			name: "Selected destination",
		});
		await expect.element(preview).toHaveTextContent("Synthetic Fencing Hall");
		await expect
			.element(preview)
			.toHaveTextContent("1 Example Street, Dublin 8");
		await expect.element(preview).toHaveTextContent("Google Maps");
		await expect
			.element(preview.getByRole("link", { name: "Venue Guide" }))
			.toHaveAttribute("referrerpolicy", "no-referrer");
		// The choice resolves in the same session the search used.
		expect(lookup.resolveCalls).toEqual([
			{
				placeId: "place_hall",
				sessionToken: lookup.suggestCalls.at(-1)?.sessionToken,
			},
		]);
		expect(recorded.requests()).toBe(0);

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationName: "Synthetic Fencing Hall",
			destinationAddress: "1 Example Street, Dublin 8",
			directionsUrl: "",
			destinationPlaceId: "place_hall",
			destinationAttributions: JSON.stringify(hall.attributions),
		});
	});

	it("dismisses suggestions with Escape and keeps manual entry working", async () => {
		const screen = await completeEditForm();

		await userEvent.click(searchBox(screen));
		await userEvent.keyboard("Synthetic");
		await expect.element(screen.getByRole("option").first()).toBeVisible();
		await userEvent.keyboard("{Escape}");
		await expect
			.element(screen.getByRole("option").first())
			.not.toBeInTheDocument();
		expect(lookup.resolveCalls).toEqual([]);

		await userEvent.fill(
			screen.getByRole("textbox", { name: "Destination name", exact: true }),
			"Our Own Hall",
		);
		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationName: "Our Own Hall",
			destinationPlaceId: "",
		});
	});

	it("explains an unavailable or unconfigured Google and keeps entered values", async () => {
		lookup.suggestFailure =
			"Google venue search isn't set up; enter the destination details manually";
		const screen = await completeEditForm();
		const name = screen.getByRole("textbox", {
			name: "Destination name",
			exact: true,
		});
		await userEvent.fill(name, "Typed before searching");

		await userEvent.click(searchBox(screen));
		await userEvent.keyboard("Synthetic");
		await expect
			.element(screen.getByRole("status").filter({ hasText: "isn't set up" }))
			.toBeVisible();
		await expect.element(name).toHaveValue("Typed before searching");

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationName: "Typed before searching",
			destinationPlaceId: "",
		});
	});

	it("says when nothing matches", async () => {
		const screen = await completeEditForm();

		await userEvent.click(searchBox(screen));
		await userEvent.keyboard("Nowhere");
		await expect
			.element(screen.getByText("No places found", { exact: false }))
			.toBeVisible();
	});

	it("keeps a saved selection on an unrelated edit", async () => {
		const screen = await completeEditForm({
			destination_name: "Synthetic Fencing Hall",
			destination_address: "1 Example Street, Dublin 8",
			destination_place_id: "place_hall",
			destination_attributions: "[]",
		});

		const preview = screen.getByRole("region", {
			name: "Selected destination",
		});
		await expect.element(preview).toHaveTextContent("Synthetic Fencing Hall");
		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationName: "Synthetic Fencing Hall",
			destinationPlaceId: "place_hall",
		});
	});

	it("removing a selection clears its provider identity before a manual destination", async () => {
		const screen = await completeEditForm({
			destination_name: "Synthetic Fencing Hall",
			destination_address: "1 Example Street, Dublin 8",
			destination_place_id: "place_hall",
			destination_attributions: "[]",
		});

		await screen
			.getByRole("button", { name: "Remove and enter manually" })
			.click();
		const name = screen.getByRole("textbox", {
			name: "Destination name",
			exact: true,
		});
		await expect.element(name).toHaveValue("");
		await userEvent.fill(name, "Our Own Hall");

		expect(await submit(screen, "Update Workshop")).toMatchObject({
			destinationName: "Our Own Hall",
			destinationAddress: "",
			destinationPlaceId: "",
			destinationAttributions: "",
		});
	});
});
