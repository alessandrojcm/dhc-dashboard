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
