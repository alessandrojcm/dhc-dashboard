import type {
	BeginnersWorkshop,
	BeginnersWorkshopStaffCandidate,
} from "@dhc/api-client";
import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import StaffDialog from "./staff-dialog.svelte";

const AOIFE = "0f3f9d0c-3b52-4a4f-9a51-6a3f1b2a2f10";
const BRIAN = "5a3c7c8e-2f1b-4c55-8d0b-1a6f0f7e9b21";
const CARA = "8c1e2d3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f";
const DARA = "1b2c3d4e-5f60-4718-8293-a4b5c6d7e8f9";

const candidates: BeginnersWorkshopStaffCandidate[] = [
	{ principalId: AOIFE, name: "Aoife Coach", coach: true },
	{ principalId: BRIAN, name: "Brian Coach", coach: true },
	{ principalId: CARA, name: "Cara Member", coach: false },
];

function workshop(
	overrides: Partial<BeginnersWorkshop> = {},
): BeginnersWorkshop {
	return {
		id: "6d9e6110-fc8c-4dcf-b64f-db21b20d5140",
		status: "scheduled",
		venue: "St. Andrew's Hall",
		date: "2026-11-14",
		startTime: "18:30",
		capacity: 16,
		feeCents: 4000,
		paymentCutoff: "2026-11-11T18:30:00Z",
		paymentCutoffDate: "2026-11-11",
		paymentCutoffTime: "18:30",
		contactFromDate: "2026-10-09",
		contactFromEditable: true,
		paymentWindowDays: 7,
		stage: "next_batch_due",
		seats: {
			capacity: 16,
			paid: 0,
			holds: 0,
			free: 16,
			attended: 0,
			noShow: 0,
		},
		alerts: ["unstaffed"],
		staff: { coach: null, assistants: [] },
		...overrides,
	};
}

/** The submitted Staff, read from the form's hidden inputs (suffix stripped). */
function submitted(form: Element) {
	if (!(form instanceof HTMLFormElement)) throw new Error("not a form");
	const entries = [...new FormData(form).entries()].map(
		([name, value]) =>
			[name.split("/")[0], value instanceof File ? value.name : value] as const,
	);
	return {
		coach: entries.find(([name]) => name === "coachPrincipalId")?.[1] ?? null,
		assistants: entries
			.filter(([name]) => name.startsWith("assistantPrincipalIds["))
			.map(([, value]) => value),
	};
}

async function openDialog(staffed: Partial<BeginnersWorkshop> = {}) {
	const screen = await render(StaffDialog, {
		workshop: workshop(staffed),
		candidates,
		open: true,
	});
	const form = screen.getByRole("form", { name: "Workshop Staff" });
	await expect.element(form).toBeVisible();
	return { screen, form };
}

test("the coach select lists only coaches", async () => {
	const { screen } = await openDialog();

	await userEvent.click(screen.getByRole("combobox", { name: "Coach" }));
	const options = screen.getByRole("option");
	await expect.element(options.first()).toBeVisible();
	expect(
		options
			.elements()
			.map((option) => option.textContent?.replace(/\s+/g, " ").trim()),
	).toEqual(["Aoife Coach coach", "Brian Coach coach"]);
});

test("picks a coach and assistants, shown as removable chips", async () => {
	const { screen, form } = await openDialog();

	await userEvent.click(screen.getByRole("combobox", { name: "Coach" }));
	await userEvent.click(screen.getByRole("option", { name: /Aoife Coach/ }));
	await expect
		.element(screen.getByRole("combobox", { name: "Coach" }))
		.toHaveTextContent("Aoife Coach");

	await userEvent.click(screen.getByRole("combobox", { name: "Assistants" }));
	// The coach is not offered as an assistant; everyone else is.
	await expect
		.element(screen.getByRole("option", { name: /Cara Member/ }))
		.toBeVisible();
	expect(
		screen.getByRole("option", { name: /Aoife Coach/ }).elements(),
	).toHaveLength(0);
	await userEvent.click(screen.getByRole("option", { name: /Cara Member/ }));
	await userEvent.click(screen.getByRole("option", { name: /Brian Coach/ }));
	await userEvent.keyboard("{Escape}");

	const chips = screen.getByRole("list", { name: "Selected assistants" });
	await expect.element(chips).toHaveTextContent("Cara Member");
	await expect.element(chips).toHaveTextContent("Brian Coach · coach");
	expect(submitted(form.element())).toEqual({
		coach: AOIFE,
		assistants: [CARA, BRIAN],
	});

	await userEvent.click(
		screen.getByRole("button", { name: "Remove Cara Member" }),
	);
	expect(submitted(form.element())).toEqual({
		coach: AOIFE,
		assistants: [BRIAN],
	});
});

test("picking an assistant as coach removes them from the assistants", async () => {
	const { screen, form } = await openDialog({
		staff: {
			coach: { principalId: AOIFE, name: "Aoife Coach" },
			assistants: [{ principalId: BRIAN, name: "Brian Coach" }],
		},
	});
	expect(submitted(form.element())).toEqual({
		coach: AOIFE,
		assistants: [BRIAN],
	});

	await userEvent.click(screen.getByRole("combobox", { name: "Coach" }));
	await userEvent.click(screen.getByRole("option", { name: /Brian Coach/ }));

	expect(submitted(form.element())).toEqual({ coach: BRIAN, assistants: [] });
});

test("clearing the coach leaves the workshop Unstaffed", async () => {
	const { screen, form } = await openDialog({
		staff: {
			coach: { principalId: AOIFE, name: "Aoife Coach" },
			assistants: [],
		},
	});

	await userEvent.click(
		screen.getByRole("button", { name: "Clear coach (Unstaffed)" }),
	);

	await expect
		.element(screen.getByRole("combobox", { name: "Coach" }))
		.toHaveTextContent("No coach yet (Unstaffed)");
	expect(submitted(form.element())).toEqual({ coach: null, assistants: [] });
});

test("keeps a coach who has since lost the coach role pickable", async () => {
	const { screen } = await openDialog({
		staff: {
			coach: { principalId: DARA, name: "Dara Former" },
			assistants: [],
		},
	});

	await expect
		.element(screen.getByRole("combobox", { name: "Coach" }))
		.toHaveTextContent("Dara Former");
});
