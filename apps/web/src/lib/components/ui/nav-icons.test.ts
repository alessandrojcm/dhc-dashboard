import { describe, expect, test } from "vitest";
import { navigation } from "#lib/server/authorization/navigation.js";
import { navIconFor } from "./nav-icons.js";

// Every sidebar entry needs an icon: `navIconFor` throws for an unknown URL,
// which turns the whole dashboard layout into a 500 for whoever sees it.
describe("navIcons", () => {
	const urls = navigation.flatMap((group) => [
		group.url,
		...(group.items ?? []).map((item) => item.url),
	]);

	test.each(urls)("%s has an icon", (url) => {
		expect(() => navIconFor(url)).not.toThrow();
	});
});
