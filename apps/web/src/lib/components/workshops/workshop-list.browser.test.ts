import type { Workshop } from "@dhc/api-client";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import { onHostTimeZone } from "#lib/testing/host-time-zone.js";
import WorkshopListTestWrapper from "./workshop-list.test-wrapper.svelte";

// Eight hours behind Dublin, so a reader's-zone date or time would show.
onHostTimeZone("America/Los_Angeles");

function workshop(overrides: Partial<Workshop> = {}): Workshop {
	return {
		id: "11111111-1111-1111-1111-111111111111",
		title: "Workshop",
		description: null,
		location: "Main Hall",
		startDate: "2026-09-01T10:00:00Z",
		endDate: "2026-09-01T12:00:00Z",
		maxCapacity: 10,
		priceMember: 1000,
		priceNonMember: 1500,
		isPublic: false,
		refundDays: 3,
		status: "published",
		interestCount: 0,
		pendingRegistrationCount: 0,
		confirmedRegistrationCount: 0,
		registrationCount: 0,
		placesRemaining: 10,
		isAtCapacity: false,
		currentUserInterest: false,
		currentUserRegistration: null,
		...overrides,
	};
}

test("uses the Workshop capacity projection to disable registration when full", async () => {
	const screen = await render(WorkshopListTestWrapper, {
		workshops: [
			workshop({
				title: "Full workshop",
				registrationCount: 10,
				placesRemaining: 0,
				isAtCapacity: true,
			}),
		],
	});

	await expect
		.element(screen.getByRole("heading", { name: "Fully booked" }))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Fully booked" }))
		.toBeDisabled();
});

test("displays the projected remaining places for an available Workshop", async () => {
	const screen = await render(WorkshopListTestWrapper, {
		workshops: [
			workshop({
				title: "Available workshop",
				registrationCount: 7,
				placesRemaining: 3,
			}),
		],
	});

	await expect.element(screen.getByText("3 places left")).toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Register" }))
		.toBeEnabled();
});

test("keeps registration available without inventing a limit for an uncapped Workshop", async () => {
	const screen = await render(WorkshopListTestWrapper, {
		workshops: [
			workshop({
				title: "Uncapped workshop",
				maxCapacity: null,
				registrationCount: 7,
				placesRemaining: null,
				isAtCapacity: false,
			}),
		],
	});

	await expect.element(screen.getByText("No capacity limit")).toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Register" }))
		.toBeEnabled();
});

test("shows each Workshop's day and times on the Dublin clock, either side of the October change", async () => {
	const screen = await render(WorkshopListTestWrapper, {
		workshops: [
			workshop({
				id: "11111111-1111-1111-1111-111111111111",
				title: "Clock change longsword",
				// 00:30 Irish Summer Time to 01:30 GMT on Sunday 25 October: two
				// hours that read as one on the Dublin wall clock. In LA it is
				// still Saturday afternoon.
				startDate: "2026-10-24T23:30:00Z",
				endDate: "2026-10-25T01:30:00Z",
			}),
			workshop({
				id: "22222222-2222-2222-2222-222222222222",
				title: "Sabre basics",
				// GMT: 18:30–20:30 Dublin, 11:30–13:30 in LA.
				startDate: "2026-10-31T18:30:00Z",
				endDate: "2026-10-31T20:30:00Z",
			}),
		],
	});

	await expect
		.element(screen.getByText("Sun, 25 Oct · 12:30 AM–1:30 AM"))
		.toBeVisible();
	await expect
		.element(screen.getByText("Sat, 31 Oct · 6:30 PM–8:30 PM"))
		.toBeVisible();
	await expect
		.element(screen.getByRole("article").first())
		.toHaveTextContent(/Oct\s*25\s*Sun/);
});
