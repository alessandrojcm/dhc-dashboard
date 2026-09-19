import { describe, expect, it } from "vitest";
import { inventoryCatalogShowItemQueryKey } from "@dhc/api-client";

describe("inventoryCatalogShowItemQueryKey", () => {
	it("is an object tuple keyed by slugOrId, not a string array", () => {
		const key = inventoryCatalogShowItemQueryKey({
			path: { slugOrId: "item-000042" },
		});
		expect(key).toHaveLength(1);
		expect(key[0]._id).toBe("inventoryCatalogShowItem");
		expect(key[0].path).toEqual({ slugOrId: "item-000042" });
		expect(key).not.toEqual(["inventoryCatalogShowItem"]);
	});
});
