import type {
	InvitationsCreateData,
	InvitationsCreateResponse,
	InvitationsResendData,
	InvitationsResendResponse,
	Options,
	WaitlistEntry,
} from "@dhc/api-client";
import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import WaitlistTableTestWrapper from "./waitlist-table.test-wrapper.svelte";

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
		...overrides,
	};
}

test("desktop and mobile invite buttons reach the same action", async () => {
	const waiting = entry("a", { fullName: "Ada Waiting" });
	const invited = entry("b", { fullName: "Bea Invited", status: "invited" });
	const createInvitations = vi.fn(
		async (
			_options: Options<InvitationsCreateData>,
		): Promise<InvitationsCreateResponse> => ({}),
	);
	const resendInvitations = vi.fn(
		async (
			_options: Options<InvitationsResendData>,
		): Promise<InvitationsResendResponse> => ({}),
	);
	const listEntries = vi.fn(async () => ({
		data: {
			entries: [waiting, invited],
			totalCount: 2,
			limit: 10 as const,
			nextCursor: null,
			previousCursor: null,
		},
	}));

	const screen = await render(WaitlistTableTestWrapper, {
		deps: {
			listEntries,
			createInvitations,
			resendInvitations,
			notify: { success: () => {}, error: () => {} },
			url: () => new URL("https://dhc.test/dashboard/beginners-workshop"),
			navigate: () => {},
		},
	});

	// Tailwind is not loaded, so both layouts render side by side.
	const desktop = screen.getByRole("table");
	const mobile = screen.getByRole("list", { name: "Waitlist entries" });
	const desktopRow = (name: string) =>
		desktop.getByRole("row").filter({ hasText: name });
	const mobileCard = (name: string) =>
		mobile.getByRole("listitem").filter({ hasText: name });

	await expect.element(desktopRow("Ada Waiting")).toBeVisible();

	// Each click optimistically marks the entry `invited` until the settled
	// request refetches the page, so wait for the server status to return.
	async function clickInvite(
		target: ReturnType<typeof desktopRow>,
		request: typeof createInvitations | typeof resendInvitations,
		status: "waiting" | "invited",
	) {
		const calls = request.mock.calls.length;
		await target.getByRole("button", { name: "Invite Member" }).click();
		await expect.poll(() => request.mock.calls.length).toBe(calls + 1);
		await expect
			.poll(() => listEntries.mock.calls.length)
			.toBeGreaterThan(fetches);
		fetches = listEntries.mock.calls.length;
		await expect
			.element(target.getByText(status, { exact: true }))
			.toBeVisible();
	}
	let fetches = listEntries.mock.calls.length;

	await clickInvite(desktopRow("Ada Waiting"), createInvitations, "waiting");
	await clickInvite(mobileCard("Ada Waiting"), createInvitations, "waiting");
	await clickInvite(desktopRow("Bea Invited"), resendInvitations, "invited");
	await clickInvite(mobileCard("Bea Invited"), resendInvitations, "invited");

	expect(createInvitations.mock.calls.map(([options]) => options.body)).toEqual(
		[{ invites: ["a"] }, { invites: ["a"] }],
	);
	expect(resendInvitations.mock.calls.map(([options]) => options.body)).toEqual(
		[{ emails: ["b@test.com"] }, { emails: ["b@test.com"] }],
	);
});
