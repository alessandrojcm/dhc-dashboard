import type { BeginnersWorkshopInvitable } from "@dhc/api-client";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import InvitableTab from "./invitable-tab.svelte";

const person = (
	overrides: Partial<BeginnersWorkshopInvitable> = {},
): BeginnersWorkshopInvitable => ({
	intakeId: "0a5d4c9e-1111-4f3a-9b1e-7d2c3b4a5f60",
	workshopId: "6d9e6110-fc8c-4dcf-b64f-db21b20d5140",
	workshopDate: "2026-11-14",
	waitlistId: "7b1d2c3e-4f50-4617-8293-a4b5c6d7e8f9",
	firstName: "Aoife",
	lastName: "Byrne",
	email: "aoife@example.com",
	followUp: { status: "scheduled", at: "2026-11-15T10:00:00Z" },
	...overrides,
});

test("ALE-392: lists each Invitable person with the workshop, the Follow-up and Invite", async () => {
	const screen = await render(InvitableTab, {
		people: [
			person(),
			person({
				intakeId: "0a5d4c9e-2222-4f3a-9b1e-7d2c3b4a5f60",
				firstName: "Bea",
				lastName: "Kelly",
				email: "bea@example.com",
				followUp: { status: "sent", at: "2026-11-15T10:00:02Z" },
			}),
		],
	});

	const rows = screen.getByTestId("invitable-row");
	expect(rows.elements()).toHaveLength(2);
	const aoife = rows.filter({ hasText: "Aoife Byrne" });
	await expect.element(aoife).toHaveTextContent("aoife@example.com");
	await expect.element(aoife).toHaveTextContent("Sat 14 Nov 2026");
	await expect.element(aoife).toHaveTextContent("Scheduled Sun 15 Nov, 10:00");
	await expect
		.element(aoife.getByRole("link", { name: "Sat 14 Nov 2026" }))
		.toHaveAttribute(
			"href",
			"/dashboard/beginners-workshop/workshops/6d9e6110-fc8c-4dcf-b64f-db21b20d5140",
		);
	await expect
		.element(rows.filter({ hasText: "Bea Kelly" }))
		.toHaveTextContent("Sent Sun 15 Nov, 10:00");
	expect(
		screen.getByRole("button", { name: "Invite" }).elements(),
	).toHaveLength(2);
});

test("ALE-392: says nobody is waiting for an Invitation", async () => {
	const screen = await render(InvitableTab, { people: [] });

	await expect.element(screen.getByText("Nobody to invite")).toBeVisible();
});
