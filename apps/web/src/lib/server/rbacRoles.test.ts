import { describe, expect, it } from "vitest";
import { canAccessUrl, filterNavByRoles, navData } from "$lib/server/rbacRoles";

describe("inventory navigation", () => {
	it("shows structure management only to inventory operators", () => {
		expect(
			filterNavByRoles(navData, ["quartermaster"]).navMain.some(
				(item) => item.title === "Inventory",
			),
		).toBe(true);
		expect(
			filterNavByRoles(navData, ["member"]).navMain.some(
				(item) => item.title === "Inventory",
			),
		).toBe(false);
	});

	it("governs nested inventory routes", () => {
		expect(
			canAccessUrl("/dashboard/inventory/items", new Set(["quartermaster"])),
		).toBe(true);
		expect(
			canAccessUrl("/dashboard/inventory/categories", new Set(["admin"])),
		).toBe(true);
		expect(
			canAccessUrl("/dashboard/inventory/containers", new Set(["member"])),
		).toBe(false);
	});
});
