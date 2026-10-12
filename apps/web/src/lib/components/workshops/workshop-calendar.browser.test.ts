import type { WorkshopCalendarItem } from "@dhc/api-client";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import { onHostTimeZone } from "#lib/testing/host-time-zone.js";
import WorkshopCalendar from "./workshop-calendar.svelte";

// Eight hours behind Dublin, so an event placed by the reader's zone lands a
// day early.
onHostTimeZone("America/Los_Angeles");

const workshop: WorkshopCalendarItem = {
	id: "11111111-1111-1111-1111-111111111111",
	title: "Clock change longsword",
	description: null,
	location: "Main Hall",
	// 00:30 Irish Summer Time on Sunday 25 October, the night the clocks go
	// back; in LA it is still Saturday afternoon.
	startDate: "2026-10-24T23:30:00Z",
	endDate: "2026-10-25T01:30:00Z",
	maxCapacity: 10,
	priceMember: 1000,
	priceNonMember: 1500,
	isPublic: false,
	refundDays: 3,
	status: "published",
	announceDiscord: false,
	announceEmail: false,
	createdBy: null,
	interestCount: 0,
	pendingRegistrationCount: 0,
	confirmedRegistrationCount: 0,
	registrationCount: 0,
	placesRemaining: 10,
	isAtCapacity: false,
};

function calendarTitle() {
	return document.querySelector(".ec-title")?.textContent?.trim() ?? "";
}

/** Months since year 0 for a title such as `October 2026`. */
function monthIndex(title: string) {
	const date = new Date(`1 ${title} 12:00 UTC`);
	return date.getUTCFullYear() * 12 + date.getUTCMonth();
}

test("places a Workshop on its Dublin day and time", async () => {
	const screen = await render(WorkshopCalendar, {
		workshops: [workshop],
		isLoading: false,
	});

	// The calendar opens on the current month; step to October 2026.
	await expect.poll(calendarTitle).not.toBe("");
	const steps = monthIndex("October 2026") - monthIndex(calendarTitle());
	for (let step = 0; step < Math.abs(steps); step += 1) {
		const before = calendarTitle();
		// The arrows have no accessible name (the shared calendar options
		// replace `buttonText`), so find them by event-calendar's own classes.
		document
			.querySelector<HTMLButtonElement>(
				steps > 0 ? "button.ec-next" : "button.ec-prev",
			)
			?.click();
		await expect.poll(calendarTitle).not.toBe(before);
	}
	expect(calendarTitle()).toBe("October 2026");

	const chip = screen.getByTitle("Clock change longsword");
	await expect.element(chip).toHaveTextContent(/00:30/);
	const day = chip.element().closest(".ec-day");
	expect(day?.querySelector(".ec-day-head")?.textContent?.trim()).toBe("25");
});
