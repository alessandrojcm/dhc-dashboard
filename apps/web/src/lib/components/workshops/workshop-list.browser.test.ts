import type { Workshop } from "@dhc/api-client";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import WorkshopListTestWrapper from "./workshop-list.test-wrapper.svelte";

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
