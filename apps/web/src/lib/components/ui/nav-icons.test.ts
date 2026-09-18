import { describe, expect, it } from "vitest";
import { navigation } from "$lib/server/authorization/navigation";
import { navIconFor, navIcons } from "./nav-icons";

describe("sidebar navigation icons", () => {
	it("has an icon for Home and for every navigation entry and sub-item", () => {
		const urls = [
			"/dashboard" as const,
			...navigation.flatMap((group) => [
				group.url,
				...(group.items ?? []).map((item) => item.url),
			]),
		];

		for (const url of urls) {
			expect(() => navIconFor(url), url).not.toThrow();
		}
	});

	it("carries no icon for URLs that are not navigation entries", () => {
		const known = new Set<string>([
			"/dashboard",
			...navigation.flatMap((group) => [
				group.url,
				...(group.items ?? []).map((item) => item.url),
			]),
		]);
		for (const url of Object.keys(navIcons)) {
			expect(known.has(url), `stale icon entry ${url}`).toBe(true);
		}
	});
});
