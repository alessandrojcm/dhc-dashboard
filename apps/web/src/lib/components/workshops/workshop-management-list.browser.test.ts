import type { WorkshopCalendarItem } from "@dhc/api-client";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import { onHostTimeZone } from "#lib/testing/host-time-zone.js";
import WorkshopManagementListTestWrapper from "./workshop-management-list.test-wrapper.svelte";

// Eight hours behind Dublin, so a reader's-zone date or time would show.
onHostTimeZone("America/Los_Angeles");

function workshop(
	overrides: Partial<WorkshopCalendarItem> = {},
): WorkshopCalendarItem {
	return {
		id: "11111111-1111-1111-1111-111111111111",
		title: "Clock change longsword",
		description: null,
		location: "Main Hall",
		destinationText: null,
		destinationProvider: null,
		destinationPlaceId: null,
		// 00:30 Irish Summer Time to 01:30 GMT on Sunday 25 October; in LA it
		// is still Saturday afternoon.
		startDate: "2026-10-24T23:30:00Z",
		endDate: "2026-10-25T01:30:00Z",
		maxCapacity: 10,
		priceMember: 1000,
		priceNonMember: 1500,
		isPublic: false,
		refundDays: 3,
		status: "planned",
		announceDiscord: false,
		announceEmail: false,
		createdBy: null,
		interestCount: 0,
		pendingRegistrationCount: 0,
		confirmedRegistrationCount: 0,
		registrationCount: 0,
		placesRemaining: 10,
		isAtCapacity: false,
		...overrides,
	};
}

test("shows a saved destination with a safe directions link in the management modal", async () => {
	// ALE-440: the familiar label stays, the manual destination text sits
	// beside it, and its Maps search opens externally.
	const screen = await render(WorkshopManagementListTestWrapper, {
		workshops: [
			workshop({
				destinationText: "National Basketball Arena, Tymon Park, Dublin 6w",
			}),
		],
	});

	const row = screen.getByRole("article");
	await row.getByRole("button", { name: "Manage" }).click();

	const dialog = screen.getByRole("dialog");
	await expect.element(dialog.getByText("Main Hall")).toBeVisible();
	await expect
		.element(
			dialog.getByText("National Basketball Arena, Tymon Park, Dublin 6w"),
		)
		.toBeVisible();

	const directions = dialog.getByRole("link", { name: "Get directions" });
	await expect.element(directions).toBeVisible();
	await expect
		.element(directions)
		.toHaveAttribute(
			"href",
			`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent("National Basketball Arena, Tymon Park, Dublin 6w")}`,
		);
	await expect.element(directions).toHaveAttribute("target", "_blank");
	await expect
		.element(directions)
		.toHaveAttribute("rel", "noopener noreferrer");
});

test("a legacy label-only Workshop shows no directions link", async () => {
	const screen = await render(WorkshopManagementListTestWrapper, {
		workshops: [workshop()],
	});

	const row = screen.getByRole("article");
	await row.getByRole("button", { name: "Manage" }).click();

	const dialog = screen.getByRole("dialog");
	await expect.element(dialog.getByText("Main Hall")).toBeVisible();
	expect(
		dialog.getByRole("link", { name: "Get directions" }).elements(),
	).toHaveLength(0);
});

test("lists and manages a Workshop on the Dublin clock across the October change", async () => {
	const screen = await render(WorkshopManagementListTestWrapper, {
		workshops: [workshop()],
	});

	const row = screen.getByRole("article");
	await expect.element(row).toHaveTextContent(/Oct\s*25/);
	await expect.element(row.getByText("Sun, 25 Oct · 12:30 AM")).toBeVisible();

	await row.getByRole("button", { name: "Manage" }).click();

	const dialog = screen.getByRole("dialog");
	await expect
		.element(dialog.getByText("Sunday, 25 October 2026"))
		.toBeVisible();
	// Two hours elapse, though the Dublin wall clock moves back an hour.
	await expect
		.element(dialog.getByText(/12:30 AM–1:30 AM\s*· 2 hr/))
		.toBeVisible();
});
