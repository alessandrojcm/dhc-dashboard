import { describe, expect, it } from "vitest";
import { isModifiedClick, sheetSelection } from "./sheet-selection";

describe("sheetSelection", () => {
	it("prefers shallow-routed page state", () => {
		expect(
			sheetSelection(
				"/dashboard/equipment/item-000001",
				"/dashboard/equipment",
				"from-state",
			),
		).toBe("from-state");
	});

	it("falls back to the detail pathname on a full load", () => {
		expect(
			sheetSelection(
				"/dashboard/equipment/item-000001",
				"/dashboard/equipment",
				undefined,
			),
		).toBe("item-000001");
		expect(
			sheetSelection(
				"/dashboard/my-loans/11111111-1111-1111-1111-111111111111",
				"/dashboard/my-loans",
				undefined,
			),
		).toBe("11111111-1111-1111-1111-111111111111");
	});

	it("closes when the URL is the list after replaceState or back", () => {
		expect(
			sheetSelection("/dashboard/equipment", "/dashboard/equipment", undefined),
		).toBeUndefined();
	});

	it("ignores nested paths that are not a single segment", () => {
		expect(
			sheetSelection(
				"/dashboard/equipment/item-000001/extra",
				"/dashboard/equipment",
				undefined,
			),
		).toBeUndefined();
	});
});

describe("isModifiedClick", () => {
	it("lets new-tab and non-primary clicks through to the real href", () => {
		expect(isModifiedClick({ button: 0, metaKey: true })).toBe(true);
		expect(isModifiedClick({ button: 1 })).toBe(true);
		expect(isModifiedClick({ button: 0 })).toBe(false);
	});
});
