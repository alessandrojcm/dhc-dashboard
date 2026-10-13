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
