import type {
	Options,
	WaitlistEntriesData,
	WaitlistEntriesResponse2,
	WaitlistEntry,
} from "@dhc/api-client";
import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import WaitlistTableTestWrapper from "./waitlist-table.test-wrapper.svelte";

const BASE = "https://dhc.test/dashboard/beginners-workshop";

function entry(id: string, overrides: Partial<WaitlistEntry>): WaitlistEntry {
	return {
		id,
		position: 1,
		fullName: `Person ${id}`,
		email: `${id}@test.com`,
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
		...overrides,
	};
}

function page(entries: WaitlistEntry[]): WaitlistEntriesResponse2 {
	return {
		data: {
			entries,
			totalCount: entries.length,
			limit: 10,
			nextCursor: null,
			previousCursor: null,
		},
	};
}

test("lists the waiting queue by default and removed people behind the filter", async () => {
	const waiting = entry("a", { fullName: "Ada Waiting" });
	const removed = entry("b", {
		fullName: "Bea Removed",
		status: "removed",
		removedAt: "2026-03-12T10:00:00Z",
	});
	const listEntries = vi.fn(async (options: Options<WaitlistEntriesData>) =>
		page(options.query?.status === "removed" ? [removed] : [waiting]),
	);
	let url = new URL(BASE);
	const navigate = vi.fn((href: string) => {
		url = new URL(href, BASE);
	});

	const screen = await render(WaitlistTableTestWrapper, {
		deps: {
			listEntries,
			notify: { success: () => {}, error: () => {} },
			url: () => url,
			navigate,
		},
	});

	// Tailwind is not loaded, so both layouts render side by side.
	const desktop = screen.getByRole("table");
	const mobile = screen.getByRole("list", { name: "Waitlist entries" });

	await expect.element(desktop.getByText("Ada Waiting")).toBeVisible();
	expect(listEntries).toHaveBeenCalledWith(
		expect.objectContaining({
			query: expect.objectContaining({ status: "waiting" }),
		}),
	);
	await expect
		.element(screen.getByRole("radio", { name: "Waiting" }))
		.toHaveAttribute("aria-checked", "true");
	await expect
		.element(desktop.getByText("Total 1 people waiting"))
		.toBeVisible();

	// Status is read-only and nobody is invited from the Waitlist view.
	expect(screen.getByRole("button", { name: /invite/i }).elements()).toEqual(
		[],
	);
	expect(screen.getByRole("combobox", { name: /status/i }).elements()).toEqual(
		[],
	);
	await expect
		.element(mobile.getByRole("listitem").getByText("Waiting", { exact: true }))
		.toBeVisible();

	await screen.getByRole("radio", { name: "Removed" }).click();

	expect(navigate).toHaveBeenCalledWith(
		expect.stringContaining("status=removed"),
		{ replace: true },
	);
});

test("renders a removed person's removal date from the URL filter", async () => {
	const removed = entry("b", {
		fullName: "Bea Removed",
		status: "removed",
		removedAt: "2026-03-12T10:00:00Z",
	});
	const listEntries = vi.fn(async () => page([removed]));

	const screen = await render(WaitlistTableTestWrapper, {
		deps: {
			listEntries,
			notify: { success: () => {}, error: () => {} },
			url: () => new URL(`${BASE}?status=removed`),
			navigate: () => {},
		},
	});

	const desktop = screen.getByRole("table");

	await expect.element(desktop.getByText("Bea Removed")).toBeVisible();
	expect(listEntries).toHaveBeenCalledWith(
		expect.objectContaining({
			query: expect.objectContaining({ status: "removed" }),
		}),
	);
	await expect
		.element(screen.getByRole("radio", { name: "Removed" }))
		.toHaveAttribute("aria-checked", "true");
	await expect.element(desktop.getByText("Removed 12/03/2026")).toBeVisible();
	await expect
		.element(desktop.getByText("Total 1 people removed"))
		.toBeVisible();
});

test("offers restore from the removed filter for a recent removal only", async () => {
	const recent = entry("b", {
		fullName: "Bea Recent",
		status: "removed",
		removedAt: "2026-09-01T10:00:00Z",
	});
	const old = entry("c", {
		fullName: "Cal Old",
		status: "removed",
		removedAt: "2026-01-01T10:00:00Z",
	});
	const restoreEntry = vi.fn(async () => ({
		data: { ...recent, status: "waiting" as const, removedAt: null },
	}));

	const screen = await render(WaitlistTableTestWrapper, {
		deps: {
			listEntries: vi.fn(async () => page([recent, old])),
			restoreEntry,
			now: () => new Date("2026-10-09T12:00:00Z"),
			notify: { success: () => {}, error: () => {} },
			url: () => new URL(`${BASE}?status=removed`),
			navigate: () => {},
		},
	});

	const desktop = screen.getByRole("table");
	await expect.element(desktop.getByText("Bea Recent")).toBeVisible();

	const restoreButtons = desktop.getByRole("button", {
		name: "Restore to the Waitlist",
	});
	expect(restoreButtons.elements()).toHaveLength(1);

	await restoreButtons.click();

	expect(restoreEntry).toHaveBeenCalledWith(
		expect.objectContaining({ path: { id: "b" } }),
	);
});

test("ALE-387: Withdraw asks to refund or forfeit only when Phoenix says the person has paid", async () => {
	const ada = entry("a", { fullName: "Ada Paid" });
	const withdrawEntry = vi
		.fn()
		.mockRejectedValueOnce({
			errors: {
				detail: "Choose whether to refund or forfeit their fee",
				code: "refund_choice_required",
				fields: { refund: ["Choose whether to refund or forfeit their fee"] },
			},
		})
		.mockResolvedValueOnce({
			data: {
				waitlistId: "a",
				status: "removed",
				intake: null,
				outcome: "done",
			},
		});
	const success = vi.fn();

	const screen = await render(WaitlistTableTestWrapper, {
		deps: {
			listEntries: vi.fn(async () => page([ada])),
			withdrawEntry,
			notify: { success, error: () => {} },
			url: () => new URL(BASE),
			navigate: () => {},
		},
	});

	const desktop = screen.getByRole("table");
	await expect.element(desktop.getByText("Ada Paid")).toBeVisible();
	await desktop
		.getByRole("button", { name: "Withdraw from the Waitlist" })
		.click();

	const dialog = screen.getByRole("dialog", {
		name: "Withdraw Ada Paid from the Waitlist",
	});
	await expect.element(dialog).toBeVisible();
	expect(dialog.getByRole("radio").elements()).toHaveLength(0);

	await dialog.getByRole("button", { name: "Withdraw", exact: true }).click();
	await expect
		.element(dialog.getByRole("alert"))
		.toHaveTextContent("Choose whether to refund or forfeit their fee");
	const submit = dialog.getByRole("button", { name: "Withdraw", exact: true });
	await expect.element(submit).toBeDisabled();

	await dialog.getByRole("radio", { name: /Refund the full fee/ }).click();
	await submit.click();

	await expect.poll(() => success.mock.calls.length).toBe(1);
	expect(withdrawEntry).toHaveBeenLastCalledWith(
		expect.objectContaining({
			path: { waitlistId: "a" },
			body: { refund: true },
		}),
	);
	expect(withdrawEntry.mock.calls[0][0]).toEqual(
		expect.objectContaining({ body: {} }),
	);
});

test("ALE-387: Withdraw is offered to waiting people, not removed ones", async () => {
	const removed = entry("b", {
		fullName: "Bea Removed",
		status: "removed",
		removedAt: "2026-09-01T10:00:00Z",
	});

	const screen = await render(WaitlistTableTestWrapper, {
		deps: {
			listEntries: vi.fn(async () => page([removed])),
			now: () => new Date("2026-10-09T12:00:00Z"),
			notify: { success: () => {}, error: () => {} },
			url: () => new URL(`${BASE}?status=removed`),
			navigate: () => {},
		},
	});

	const desktop = screen.getByRole("table");
	await expect.element(desktop.getByText("Bea Removed")).toBeVisible();
	expect(
		desktop
			.getByRole("button", { name: "Withdraw from the Waitlist" })
			.elements(),
	).toHaveLength(0);
});

// ALE-388: the Waitlist entry shows the person's Carried Fee.
test("shows a Carried Fee holder's fee on their entry", async () => {
	const holder = entry("a", { fullName: "Ada Holder" });
	const other = entry("b", { fullName: "Bea Payer", position: 2 });
	const listCarriedFees = vi.fn(async (_ids: string[]) => ({
		a: "held" as const,
	}));

	const screen = await render(WaitlistTableTestWrapper, {
		deps: {
			listEntries: vi.fn(async () => page([holder, other])),
			listCarriedFees,
			notify: { success: () => {}, error: () => {} },
			url: () => new URL(BASE),
			navigate: () => {},
		},
	});

	const desktop = screen.getByRole("table");
	await expect
		.element(desktop.getByText("Waiting · Carried Fee"))
		.toBeVisible();
	expect(listCarriedFees).toHaveBeenCalledWith(["a", "b"]);
	expect(desktop.getByText("Waiting · Carried Fee").elements()).toHaveLength(1);
	await expect
		.element(
			screen
				.getByRole("list", { name: "Waitlist entries" })
				.getByText("Waiting · Carried Fee"),
		)
		.toBeVisible();
});
