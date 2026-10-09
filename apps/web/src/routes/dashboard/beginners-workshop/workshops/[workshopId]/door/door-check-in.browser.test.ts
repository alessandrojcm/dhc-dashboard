import type {
	BeginnersWorkshopDoor,
	BeginnersWorkshopDoorPerson,
} from "@dhc/api-client";
import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import DoorCheckIn from "./door-check-in.svelte";

const WORKSHOP = "6d9e6110-fc8c-4dcf-b64f-db21b20d5140";
const CIARA = "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab001";
const DARA = "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab002";
const NIAMH = "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab003";

function person(
	overrides: Partial<BeginnersWorkshopDoorPerson>,
): BeginnersWorkshopDoorPerson {
	return {
		id: CIARA,
		firstName: "Ciara",
		lastName: "Byrne",
		pronouns: "she/her",
		state: "paid",
		minor: false,
		medicalConditions: null,
		guardian: null,
		checkedIn: null,
		...overrides,
	};
}

function door(
	overrides: Partial<BeginnersWorkshopDoor> = {},
): BeginnersWorkshopDoor {
	return {
		id: WORKSHOP,
		status: "scheduled",
		venue: "St. Andrew's Hall",
		date: "2026-11-14",
		startTime: "18:30",
		stage: "check_in_open",
		alerts: [],
		staff: { coach: null, assistants: [] },
		checkIn: { window: "open", opensAt: "2026-11-14T17:30:00Z" },
		people: [
			person({
				minor: true,
				medicalConditions: "Asthma",
				guardian: { name: "Gráinne Byrne", phoneNumber: "+353 87 000 0001" },
			}),
			person({ id: DARA, firstName: "Dara", lastName: "Kelly" }),
			person({
				id: NIAMH,
				firstName: "Niamh",
				lastName: "Walsh",
				checkedIn: { at: "2026-11-14T18:05:00Z", by: "Aoife Coach" },
			}),
		],
		finalisation: null,
		...overrides,
	};
}

/** A stand-in for Phoenix: records each call and answers the given view. */
function phoenix(answer: (intakeId: string) => BeginnersWorkshopDoor) {
	const calls: { id: string; intakeId: string }[] = [];
	const command = async (input: { id: string; intakeId: string }) => {
		calls.push(input);
		return { ok: true as const, data: answer(input.intakeId) };
	};
	return { calls, command };
}

test("counts who is in and lists who is still to arrive", async () => {
	const screen = await render(DoorCheckIn, { door: door() });

	await expect
		.element(screen.getByTestId("door-count"))
		.toHaveTextContent("1 of 3 in");
	await expect
		.element(screen.getByRole("radio", { name: "To arrive 2" }))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Check in Ciara Byrne" }))
		.toBeVisible();
	expect(screen.getByTestId("door-person").elements()).toHaveLength(2);

	await userEvent.click(screen.getByRole("radio", { name: "In 1" }));
	await expect
		.element(screen.getByTestId("door-person"))
		.toHaveTextContent("In 18:05 · by Aoife Coach");
});

test("searching by name finds people already in, and no walk-ins", async () => {
	const screen = await render(DoorCheckIn, { door: door() });

	await userEvent.fill(screen.getByRole("searchbox"), "niam");
	await expect
		.element(screen.getByTestId("door-person"))
		.toHaveTextContent("Niamh Walsh");
	expect(screen.getByTestId("door-person").elements()).toHaveLength(1);

	await userEvent.fill(screen.getByRole("searchbox"), "zed");
	await expect
		.element(screen.getByText("No one by that name. No walk-ins."))
		.toBeVisible();
});

test("Check in asks Phoenix and shows who checked the person in", async () => {
	const { calls, command } = phoenix(() => {
		const base = door();
		return {
			...base,
			people: base.people.map((p) =>
				p.id === DARA
					? {
							...p,
							checkedIn: { at: "2026-11-14T18:40:00Z", by: "Brian Assist" },
						}
					: p,
			),
		};
	});
	const screen = await render(DoorCheckIn, { door: door(), checkIn: command });

	await userEvent.click(
		screen.getByRole("button", { name: "Check in Dara Kelly" }),
	);

	expect(calls).toEqual([{ id: WORKSHOP, intakeId: DARA }]);
	await expect
		.element(screen.getByTestId("door-count"))
		.toHaveTextContent("2 of 3 in");
	await userEvent.click(screen.getByRole("radio", { name: "In 2" }));
	await expect
		.element(screen.getByText("In 18:40 · by Brian Assist"))
		.toBeVisible();
});

test("Undo clears the check-in", async () => {
	const { calls, command } = phoenix(() => {
		const base = door();
		return {
			...base,
			people: base.people.map((p) => ({ ...p, checkedIn: null })),
		};
	});
	const screen = await render(DoorCheckIn, {
		door: door(),
		undoCheckIn: command,
	});

	await userEvent.click(screen.getByRole("radio", { name: "In 1" }));
	await userEvent.click(
		screen.getByRole("button", { name: "Undo check-in for Niamh Walsh" }),
	);

	expect(calls).toEqual([{ id: WORKSHOP, intakeId: NIAMH }]);
	await expect
		.element(screen.getByTestId("door-count"))
		.toHaveTextContent("0 of 3 in");
	await expect.element(screen.getByText("Nobody in yet.")).toBeVisible();
});

test("tapping a minor's name shows medical details and a tap-to-call Guardian", async () => {
	const screen = await render(DoorCheckIn, { door: door() });

	await userEvent.click(screen.getByRole("button", { name: /^Ciara Byrne/ }));

	const details = screen.getByTestId("door-person-details");
	await expect.element(details).toHaveTextContent("Asthma");
	await expect.element(details).toHaveTextContent("Guardian Gráinne Byrne");
	await expect
		.element(screen.getByRole("link", { name: "+353 87 000 0001" }))
		.toHaveAttribute("href", "tel:+353870000001");
});

test("before the window opens it says when, and offers no Check-in", async () => {
	const screen = await render(DoorCheckIn, {
		door: door({
			stage: "today_before_check_in",
			checkIn: { window: "before", opensAt: "2026-11-14T17:30:00Z" },
		}),
	});

	await expect
		.element(screen.getByTestId("door-window"))
		.toHaveTextContent("Check-in opens Sat 14 Nov, 17:30");
	expect(
		screen.getByRole("button", { name: /^Check in / }).elements(),
	).toHaveLength(0);
});

test("Finish lists who becomes a no-show, then shows the finalised summary", async () => {
	const calls: { id: string }[] = [];
	const finishWorkshop = async (input: { id: string }) => {
		calls.push(input);
		const base = door();
		return {
			ok: true as const,
			data: door({
				status: "finalised",
				stage: "finalised",
				checkIn: { window: "closed", opensAt: base.checkIn.opensAt },
				people: base.people.map((p) => ({
					...p,
					state: p.checkedIn ? ("attended" as const) : ("no_show" as const),
				})),
				finalisation: {
					at: "2026-11-14T20:05:00Z",
					by: "Aoife Coach",
					attended: 1,
					noShow: 2,
				},
			}),
		};
	};
	const changes: string[] = [];
	const screen = await render(DoorCheckIn, {
		door: door(),
		finishWorkshop,
		onchange: (view: BeginnersWorkshopDoor) => changes.push(view.stage),
	});

	await userEvent.click(
		screen.getByRole("button", { name: "Finish workshop (2 will be no-show)" }),
	);

	const dialog = screen.getByRole("dialog");
	await expect.element(dialog).toHaveTextContent("Finish workshop?");
	const noShows = screen.getByRole("list", { name: "Will be no-show" });
	await expect.element(noShows).toHaveTextContent("Ciara Byrne");
	await expect.element(noShows).toHaveTextContent("Dara Kelly");
	await expect.element(noShows).not.toHaveTextContent("Niamh Walsh");

	await userEvent.click(screen.getByRole("button", { name: "Not yet" }));
	expect(calls).toEqual([]);

	await userEvent.click(
		screen.getByRole("button", { name: "Finish workshop (2 will be no-show)" }),
	);
	await userEvent.click(
		screen.getByRole("button", { name: "Finish workshop", exact: true }),
	);

	expect(calls).toEqual([{ id: WORKSHOP }]);
	expect(changes).toEqual(["finalised"]);
	const summary = screen.getByTestId("door-finalised");
	await expect
		.element(summary)
		.toHaveTextContent("Finalised Sat 14 Nov, 20:05 by Aoife Coach");
	await expect.element(summary).toHaveTextContent("1 attended · 2 no-show");
	await expect.element(screen.getByRole("dialog")).not.toBeInTheDocument();
	expect(
		screen.getByRole("button", { name: /^Finish workshop/ }).elements(),
	).toHaveLength(0);
	expect(
		screen.getByRole("button", { name: /^Check in / }).elements(),
	).toHaveLength(0);
});

test("before check-in opens there is no Finish", async () => {
	const screen = await render(DoorCheckIn, {
		door: door({
			stage: "today_before_check_in",
			checkIn: { window: "before", opensAt: "2026-11-14T17:30:00Z" },
		}),
	});

	await expect.element(screen.getByTestId("door-window")).toBeVisible();
	expect(
		screen.getByRole("button", { name: /^Finish workshop/ }).elements(),
	).toHaveLength(0);
});

test("an automatic finalisation says so", async () => {
	const screen = await render(DoorCheckIn, {
		door: door({
			status: "finalised",
			stage: "finalised",
			checkIn: { window: "closed", opensAt: "2026-11-14T17:30:00Z" },
			finalisation: {
				at: "2026-11-15T00:00:00Z",
				by: null,
				attended: 1,
				noShow: 2,
			},
		}),
	});

	await expect
		.element(screen.getByTestId("door-finalised"))
		.toHaveTextContent(
			"Finalised Sun 15 Nov, 00:00 automatically at the end of the day",
		);
});
