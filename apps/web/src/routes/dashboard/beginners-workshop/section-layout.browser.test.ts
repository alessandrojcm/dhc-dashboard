import "../../../app.css";
import { page } from "vitest/browser";
import { afterEach, expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import type {
	BeginnersWorkshopInvitable,
	WaitlistEntry,
} from "@dhc/api-client";
import SectionLayout from "./section-layout.test-wrapper.svelte";

afterEach(async () => {
	await page.viewport(1280, 900);
});

const entry: WaitlistEntry = {
	id: "mobile-person",
	fullName: "Ada Waiting",
	email: "ada@example.com",
	position: 1,
	phoneNumber: "0840000000",
	status: "waiting",
	age: 25,
	initialRegistrationDate: "2026-01-01T00:00:00Z",
	lastContacted: null,
	lastStatusChange: "2026-01-01T00:00:00Z",
	insuranceFormSubmitted: false,
	adminNotes: null,
	socialMediaConsent: "no",
	removedAt: null,
	availableCommands: [],
};
const deps = {
	listEntries: vi.fn(async () => ({
		data: {
			entries: [entry],
			totalCount: 1,
			limit: 10 as const,
			nextCursor: null,
			previousCursor: null,
		},
	})),
	listPeople: vi.fn(async () => ({})),
	notify: { success: () => {}, error: () => {} },
	url: () => new URL("https://dhc.test/dashboard/beginners-workshop/waitlist"),
	navigate: () => {},
};

const person: BeginnersWorkshopInvitable = {
	intakeId: "0a5d4c9e-1111-4f3a-9b1e-7d2c3b4a5f60",
	workshopId: "6d9e6110-fc8c-4dcf-b64f-db21b20d5140",
	workshopDate: "2026-11-14",
	waitlistId: "7b1d2c3e-4f50-4617-8293-a4b5c6d7e8f9",
	firstName: "Aoife",
	lastName: "Byrne",
	email: "aoife@example.com",
	followUp: { status: "sent", at: "2026-11-15T10:00:00Z" },
};

for (const [width, height] of [
	[360, 640],
	[390, 844],
	[768, 700],
	[1280, 900],
]) {
	test(`waitlist cards do not collapse below the filters at ${width}×${height}`, async () => {
		await page.viewport(width, height);
		const screen = await render(SectionLayout, { deps });
		await expect
			.element(
				screen
					.getByRole(width >= 1024 ? "table" : "list")
					.getByText("Ada Waiting"),
			)
			.toBeVisible();
		await expect
			.element(screen.getByRole("main"))
			.toMatchScreenshot(`waitlist-${width}x${height}`);
		screen
			.getByRole("button", { name: "Next", exact: true })
			.element()
			.scrollIntoView({ block: "end" });
		await expect
			.element(screen.getByRole("main"))
			.toMatchScreenshot(`waitlist-scrolled-${width}x${height}`);
	});

	test(`invite empty state does not collapse below the introduction at ${width}×${height}`, async () => {
		await page.viewport(width, height);
		const screen = await render(SectionLayout, { deps, invitable: true });
		const empty = screen.getByText("Nobody to invite");
		await expect.element(empty).toBeVisible();
		await expect
			.element(screen.getByRole("main"))
			.toMatchScreenshot(`invitable-${width}x${height}`);
		empty.element().scrollIntoView({ block: "center" });
		await expect
			.element(screen.getByRole("main"))
			.toMatchScreenshot(`invitable-scrolled-${width}x${height}`);
	});

	test(`invite cards remain readable at ${width}×${height}`, async () => {
		await page.viewport(width, height);
		const screen = await render(SectionLayout, {
			deps,
			invitable: true,
			people: [person],
		});
		await expect.element(screen.getByText("Aoife Byrne")).toBeVisible();
		await expect
			.element(screen.getByRole("main"))
			.toMatchScreenshot(`invitable-populated-${width}x${height}`);
		screen
			.getByRole("button", { name: "Invite", exact: true })
			.element()
			.scrollIntoView({ block: "end" });
		await expect
			.element(screen.getByRole("main"))
			.toMatchScreenshot(`invitable-populated-scrolled-${width}x${height}`);
	});
}
