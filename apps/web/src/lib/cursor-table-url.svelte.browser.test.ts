import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createCursorTableUrl } from "#lib/cursor-table-url.svelte.js";

type Navigation = { href: string; replace: boolean };

const BASE = "https://dhc.test";

function harness(path = "/dashboard/table") {
	let url = $state(new URL(path, BASE));
	const navigations: Navigation[] = [];

	return {
		navigations,
		get params() {
			return url.searchParams;
		},
		url: () => url,
		navigate: (href: string, options: { replace: boolean }) => {
			navigations.push({ href, replace: options.replace });
			url = new URL(href, BASE);
		},
		visit: (next: string) => {
			url = new URL(next, BASE);
		},
	};
}

const waitlistSort = {
	fields: {
		position: "position",
		fullName: "fullName",
	},
	default: "position",
} as const;

describe("createCursorTableUrl", () => {
	beforeEach(() => {
		vi.useFakeTimers();
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("builds the default request from an empty URL", () => {
		const h = harness();
		const state = createCursorTableUrl({ sort: waitlistSort, ...h });

		expect(state.request).toEqual({
			limit: 10,
			sort: "position",
			direction: "asc",
		});
		expect(state.search).toBe("");
		expect(state.pageSize).toBe(10);
	});

	it("translates URL params into the API request through the sort map", () => {
		const h = harness(
			"/dashboard/table?q=ada&cursor=c2&sort=name&direction=desc&pageSize=25&membershipStatus=active,paused",
		);
		const state = createCursorTableUrl({
			sort: {
				fields: { name: "lastName", since: "joinedAt" },
				default: "since",
			},
			filters: ["membershipStatus"],
			...h,
		});

		expect(state.request).toEqual({
			limit: 25,
			cursor: "c2",
			q: "ada",
			sort: "lastName",
			direction: "desc",
			membershipStatus: "active,paused",
		});
		expect(state.filter("membershipStatus")).toBe("active,paused");
	});

	it("namespaces every key with the prefix", () => {
		const h = harness(
			"/dashboard/table?q=ignored&inviteQ=bob&inviteCursor=ic&inviteSort=email&inviteDirection=asc&invitePageSize=50&pageSize=100",
		);
		const state = createCursorTableUrl({
			prefix: "invite",
			sort: {
				fields: { createdAt: "createdAt", email: "email" },
				default: "createdAt",
				defaultDirection: "desc",
			},
			...h,
		});

		expect(state.request).toEqual({
			limit: 50,
			cursor: "ic",
			q: "bob",
			sort: "email",
			direction: "asc",
		});

		state.setPageSize(25);
		const params = h.params;
		expect(params.get("invitePageSize")).toBe("25");
		expect(params.get("inviteCursor")).toBeNull();
		expect(params.get("pageSize")).toBe("100");
		expect(params.get("q")).toBe("ignored");
	});

	it("falls back to the defaults for an invalid sort, direction or page size", () => {
		const h = harness(
			"/dashboard/table?sort=current_position&direction=sideways&pageSize=20",
		);
		const state = createCursorTableUrl({
			sort: { ...waitlistSort, defaultDirection: "desc" },
			...h,
		});

		expect(state.request).toMatchObject({
			sort: "position",
			direction: "desc",
			limit: 10,
		});
		expect(state.table.state.sorting).toEqual([{ id: "position", desc: true }]);
	});

	it("pushes a history entry for cursor paging and keeps other params", () => {
		const h = harness("/dashboard/table?tab=waitlist&q=ada");
		const state = createCursorTableUrl({ sort: waitlistSort, ...h });

		state.goTo("next-cursor");

		expect(h.navigations).toEqual([
			{
				href: "/dashboard/table?tab=waitlist&q=ada&cursor=next-cursor",
				replace: false,
			},
		]);
		expect(state.request.cursor).toBe("next-cursor");
	});

	it("ignores paging to a missing cursor", () => {
		const h = harness();
		const state = createCursorTableUrl({ sort: waitlistSort, ...h });

		state.goTo(null);
		state.goTo(undefined);

		expect(h.navigations).toEqual([]);
	});

	it("replaces the entry and clears the cursor for a page-size change", () => {
		const h = harness("/dashboard/table?tab=waitlist&cursor=c2");
		const state = createCursorTableUrl({ sort: waitlistSort, ...h });

		state.setPageSize(25);

		expect(h.navigations).toEqual([
			{ href: "/dashboard/table?tab=waitlist&pageSize=25", replace: true },
		]);
		expect(state.pageSize).toBe(25);
	});

	it("ignores an unsupported page size", () => {
		const h = harness();
		const state = createCursorTableUrl({ sort: waitlistSort, ...h });

		state.setPageSize(20);

		expect(h.navigations).toEqual([]);
	});

	it("replaces the entry and clears the cursor for a filter change", () => {
		const h = harness("/dashboard/table?cursor=c2&membershipStatus=active");
		const state = createCursorTableUrl({
			sort: waitlistSort,
			filters: ["membershipStatus"],
			...h,
		});

		state.setFilter("membershipStatus", "paused");
		expect(h.navigations.at(-1)).toEqual({
			href: "/dashboard/table?membershipStatus=paused",
			replace: true,
		});

		state.setFilter("membershipStatus", null);
		expect(h.navigations.at(-1)).toEqual({
			href: "/dashboard/table",
			replace: true,
		});
		expect(state.filter("membershipStatus")).toBeNull();
		expect(state.request).not.toHaveProperty("membershipStatus");
	});

	describe("search", () => {
		it("updates the draft immediately and writes the URL after the debounce", () => {
			const h = harness("/dashboard/table?cursor=c2");
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.setSearch("a");
			state.setSearch("ad");
			state.setSearch("ada");

			expect(state.search).toBe("ada");
			expect(h.navigations).toEqual([]);

			vi.advanceTimersByTime(299);
			expect(h.navigations).toEqual([]);

			vi.advanceTimersByTime(1);
			expect(h.navigations).toEqual([
				{ href: "/dashboard/table?q=ada", replace: true },
			]);
			expect(state.request.q).toBe("ada");
		});

		it("removes the query param when the search is cleared", () => {
			const h = harness("/dashboard/table?q=ada");
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.setSearch("");
			expect(state.search).toBe("");
			vi.runAllTimers();

			expect(h.navigations).toEqual([
				{ href: "/dashboard/table", replace: true },
			]);
		});

		it("keeps the typed draft, including trailing spaces, after the URL catches up", () => {
			const h = harness();
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.setSearch("ada ");
			vi.runAllTimers();

			expect(h.params.get("q")).toBe("ada");
			expect(state.search).toBe("ada ");
		});

		it("keeps a pending draft when an unrelated param changes", () => {
			const h = harness();
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.setSearch("ad");
			state.setPageSize(50);

			expect(state.search).toBe("ad");
			vi.runAllTimers();
			expect(h.navigations.at(-1)).toEqual({
				href: "/dashboard/table?pageSize=50&q=ad",
				replace: true,
			});
		});

		it("follows the URL when the search param changes from outside", async () => {
			const h = harness("/dashboard/table?q=ada");
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.setSearch("grace");
			await vi.runAllTimersAsync();
			h.visit("/dashboard/table?q=ada");

			expect(state.search).toBe("ada");
		});

		it("keeps the draft while the URL write is still navigating", async () => {
			const h = harness();
			let finish = () => {};
			const state = createCursorTableUrl({
				sort: waitlistSort,
				url: h.url,
				navigate: (href) =>
					new Promise<void>((resolve) => {
						finish = () => {
							h.visit(href);
							resolve();
						};
					}),
			});

			state.setSearch("ada");
			await vi.runAllTimersAsync();
			expect(h.params.get("q")).toBeNull();
			expect(state.search).toBe("ada");

			finish();
			await vi.runAllTimersAsync();
			expect(state.search).toBe("ada");
		});

		it("drops a pending write once the user has left the page", () => {
			const h = harness();
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.setSearch("ada");
			h.visit("/dashboard/elsewhere");
			vi.runAllTimers();

			expect(h.navigations).toEqual([]);
		});
	});

	describe("TanStack table adapter", () => {
		it("exposes sorting and pagination state from the URL", () => {
			const h = harness(
				"/dashboard/table?sort=fullName&direction=desc&pageSize=50",
			);
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			expect(state.table.state.sorting).toEqual([
				{ id: "fullName", desc: true },
			]);
			expect(state.table.state.pagination).toEqual({
				pageIndex: 0,
				pageSize: 50,
			});
		});

		it("accepts a sorting value and replaces the entry without the cursor", () => {
			const h = harness("/dashboard/table?cursor=c2");
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.table.onSortingChange([{ id: "fullName", desc: true }]);

			expect(h.navigations).toEqual([
				{
					href: "/dashboard/table?sort=fullName&direction=desc",
					replace: true,
				},
			]);
			expect(state.request).toMatchObject({
				sort: "fullName",
				direction: "desc",
			});
		});

		it("accepts a sorting updater function applied to the current sorting", () => {
			const h = harness("/dashboard/table?sort=fullName");
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.table.onSortingChange((current) =>
				current.map((sort) => ({ ...sort, desc: !sort.desc })),
			);

			expect(h.params.get("sort")).toBe("fullName");
			expect(h.params.get("direction")).toBe("desc");
		});

		it("ignores a sorting change to an unknown column or to no sorting", () => {
			const h = harness();
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.table.onSortingChange([{ id: "email", desc: false }]);
			state.table.onSortingChange([]);

			expect(h.navigations).toEqual([]);
		});

		it("accepts pagination value and updater forms", () => {
			const h = harness();
			const state = createCursorTableUrl({ sort: waitlistSort, ...h });

			state.table.onPaginationChange({ pageIndex: 0, pageSize: 25 });
			expect(h.params.get("pageSize")).toBe("25");

			state.table.onPaginationChange((current) => ({
				...current,
				pageSize: current.pageSize * 2,
			}));
			expect(h.params.get("pageSize")).toBe("50");
			expect(h.navigations.every((n) => n.replace)).toBe(true);
		});
	});
});
