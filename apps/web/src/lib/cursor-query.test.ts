import { describe, expect, it } from "vitest";
import {
	PAGE_SIZE_OPTIONS,
	parsePageSize,
	transitionCursorQuery,
} from "$lib/cursor-query";

describe("cursor query", () => {
	it("owns the supported page sizes", () => {
		expect(PAGE_SIZE_OPTIONS).toEqual([10, 25, 50, 100]);
	});

	it.each([
		["missing", "", 10],
		["supported", "pageSize=25", 25],
		["unsupported", "pageSize=20", 10],
		["non-numeric", "pageSize=many", 10],
	])("parses a %s page size", (_case, query, expected) => {
		expect(parsePageSize(new URLSearchParams(query), "pageSize")).toBe(
			expected,
		);
	});

	it("parses a namespaced page size", () => {
		const params = new URLSearchParams("pageSize=25&invitePageSize=50");

		expect(parsePageSize(params, "invitePageSize")).toBe(50);
	});

	it("advances the relevant cursor and preserves unrelated parameters", () => {
		const current = new URLSearchParams(
			"cursor=member-page&inviteCursor=invite-page&tab=invitations",
		);

		const next = transitionCursorQuery(current, {
			cursorKey: "inviteCursor",
			cursor: "next-invite-page",
		});

		expect(next.get("inviteCursor")).toBe("next-invite-page");
		expect(next.get("cursor")).toBe("member-page");
		expect(next.get("tab")).toBe("invitations");
		expect(current.get("inviteCursor")).toBe("invite-page");
	});

	it.each([
		["page size", { pageSize: "50" }, "pageSize", "50"],
		["search", { q: "smith" }, "q", "smith"],
		["sort", { sort: "email", direction: "desc" }, "direction", "desc"],
		["filter", { membershipStatus: "paused" }, "membershipStatus", "paused"],
	] as const)(
		"clears the cursor when %s changes",
		(_case, updates, updatedKey, expectedValue) => {
			const current = new URLSearchParams("cursor=stale&keep=this");

			const next = transitionCursorQuery(current, {
				cursorKey: "cursor",
				updates,
			});

			expect(next.has("cursor")).toBe(false);
			expect(next.get(updatedKey)).toBe(expectedValue);
			expect(next.get("keep")).toBe("this");
		},
	);

	it("deletes cleared query values while resetting only the namespaced cursor", () => {
		const current = new URLSearchParams(
			"cursor=member-page&inviteCursor=invite-page&inviteQ=old&keep=this",
		);

		const next = transitionCursorQuery(current, {
			cursorKey: "inviteCursor",
			updates: { inviteQ: null },
		});

		expect(next.has("inviteCursor")).toBe(false);
		expect(next.has("inviteQ")).toBe(false);
		expect(next.get("cursor")).toBe("member-page");
		expect(next.get("keep")).toBe("this");
	});
});
