import type {
	BeginnersWorkshop,
	BeginnersWorkshopFastTrackCandidate,
} from "@dhc/api-client";
import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import FastTrackDialog from "./fast-track-dialog.test-wrapper.svelte";

const WORKSHOP = "6d9e6110-fc8c-4dcf-b64f-db21b20d5140";
const AOIFE = "0f3f9d0c-3b52-4a4f-9a51-6a3f1b2a2f10";
const BRIAN = "5a3c7c8e-2f1b-4c55-8d0b-1a6f0f7e9b21";

const workshop: BeginnersWorkshop = {
	id: WORKSHOP,
	status: "scheduled",
	venue: "St. Andrew's Hall",
	date: "2026-11-14",
	startTime: "18:30",
	capacity: 16,
	feeCents: 4000,
	paymentCutoff: "2026-11-11T18:30:00Z",
	paymentCutoffDate: "2026-11-11",
	paymentCutoffTime: "18:30",
	contactFromDate: "2026-10-20",
	contactFromEditable: false,
	paymentWindowDays: 7,
	stage: "window_open",
	seats: { capacity: 16, paid: 0, holds: 0, free: 16 },
	alerts: [],
	staff: { coach: null, assistants: [] },
};

const people: BeginnersWorkshopFastTrackCandidate[] = [
	{
		waitlistId: AOIFE,
		firstName: "Aoife",
		lastName: "Byrne",
		email: "aoife@example.com",
		status: "waiting",
		removedAt: null,
		minor: false,
	},
	{
		waitlistId: BRIAN,
		firstName: "Brian",
		lastName: "Nolan",
		email: "brian@example.com",
		status: "removed",
		removedAt: "2026-08-01T12:00:00Z",
		minor: true,
	},
];

/** A stand-in for Phoenix's search that records each query. */
function search() {
	const queries: string[] = [];
	const request = async (query: string) => {
		queries.push(query);
		const needle = query.toLowerCase();
		return people.filter((person) =>
			`${person.firstName} ${person.lastName} ${person.email}`
				.toLowerCase()
				.includes(needle),
		);
	};
	return { queries, request };
}

/** A form's submitted values, by field name (remote-form suffixes stripped). */
function submitted(form: Element) {
	if (!(form instanceof HTMLFormElement)) throw new Error("not a form");
	return Object.fromEntries(
		[...new FormData(form).entries()].map(([name, value]) => [
			name.replace(/^[^\w]+/, "").split("/")[0],
			value instanceof File ? value.name : value,
		]),
	);
}

test("lists waiting and recently removed people, each placed by its own form", async () => {
	const { request } = search();
	const screen = await render(FastTrackDialog, {
		workshop,
		fastTrackOpen: true,
		searchCandidates: request,
	});

	await expect
		.element(screen.getByRole("heading", { name: /Fast-track into/ }))
		.toBeVisible();
	const list = screen.getByRole("list", { name: "Fast-track candidates" });
	await expect.element(list).toHaveTextContent("Aoife Byrne");
	await expect.element(list).toHaveTextContent("Brian Nolan");

	const brian = screen.getByRole("listitem").filter({ hasText: "Brian Nolan" });
	await expect.element(brian).toHaveTextContent("Removed · restores");
	await expect.element(brian).toHaveTextContent("Minor");
	const aoife = screen.getByRole("listitem").filter({ hasText: "Aoife Byrne" });
	expect(aoife.element().textContent).not.toContain("Removed");

	const form = screen.getByRole("form", { name: "Fast-track Brian Nolan" });
	expect(submitted(form.element())).toEqual({
		id: WORKSHOP,
		waitlistId: BRIAN,
	});
	await expect
		.element(
			screen.getByRole("button", { name: "Not on the Waitlist? Add them" }),
		)
		.toBeVisible();
});

test("searching asks Phoenix with the typed text", async () => {
	const { queries, request } = search();
	const screen = await render(FastTrackDialog, {
		workshop,
		fastTrackOpen: true,
		searchCandidates: request,
	});
	const list = screen.getByRole("list", { name: "Fast-track candidates" });
	await expect.element(list).toHaveTextContent("Brian Nolan");

	await userEvent.fill(screen.getByRole("searchbox"), "aoife");

	await expect.poll(() => queries.at(-1)).toBe("aoife");
	await expect
		.poll(() => list.element().textContent ?? "")
		.not.toContain("Brian Nolan");
	await expect.element(list).toHaveTextContent("Aoife Byrne");

	await userEvent.fill(screen.getByRole("searchbox"), "nobody");
	await expect.element(screen.getByText("No one matches")).toBeVisible();
});

test("“Not on the Waitlist? Add them” opens the registration form, and Back returns", async () => {
	const { request } = search();
	const screen = await render(FastTrackDialog, {
		workshop,
		fastTrackOpen: true,
		searchCandidates: request,
	});

	await userEvent.click(
		screen.getByRole("button", { name: "Not on the Waitlist? Add them" }),
	);

	const form = screen.getByRole("form", { name: "Add a new person" });
	await expect.element(form).toBeVisible();
	for (const label of ["First name", "Last name", "Email", "Phone number"]) {
		await expect.element(screen.getByLabelText(label)).toBeVisible();
	}
	await expect
		.element(screen.getByRole("combobox", { name: "Gender" }))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Add and fast-track" }))
		.toBeVisible();

	await userEvent.fill(screen.getByLabelText("First name"), "Ciara");
	await userEvent.fill(screen.getByLabelText("Email"), "ciara@example.com");
	const values = submitted(form.element());
	expect(values.id).toBe(WORKSHOP);
	expect(values.firstName).toBe("Ciara");
	expect(values.email).toBe("ciara@example.com");

	await userEvent.click(screen.getByRole("button", { name: "Back" }));
	await expect
		.element(screen.getByRole("list", { name: "Fast-track candidates" }))
		.toBeVisible();
});

test("after the Payment Cutoff it explains that nobody can be fast-tracked", async () => {
	const { queries, request } = search();
	const screen = await render(FastTrackDialog, {
		workshop,
		fastTrackOpen: false,
		searchCandidates: request,
	});

	await expect
		.element(screen.getByText(/Payment is closed for this workshop/))
		.toBeVisible();
	expect(screen.getByRole("searchbox").elements()).toHaveLength(0);
	expect(
		screen
			.getByRole("button", { name: "Not on the Waitlist? Add them" })
			.elements(),
	).toHaveLength(0);
	expect(queries).toEqual([]);
});
