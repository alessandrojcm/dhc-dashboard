import { describe, expect, it } from "vitest";
import { cn } from "$lib/utils.js";
import { sheetVariants } from "./sheet-content.svelte";

type Viewport = "mobile" | "desktop";

function tokenAppliesAt(token: string, viewport: Viewport): boolean {
	if (token.startsWith("max-sm:")) return viewport === "mobile";
	if (token.startsWith("sm:")) return viewport === "desktop";
	return true;
}

function slideAxes(className: string, viewport: Viewport) {
	const tokens = className
		.split(/\s+/)
		.filter(Boolean)
		.filter((token) => tokenAppliesAt(token, viewport));

	return {
		enterX: tokens.some(
			(token) =>
				token.includes("slide-in-from-right") ||
				token.includes("slide-in-from-left"),
		),
		enterY: tokens.some(
			(token) =>
				token.includes("slide-in-from-bottom") ||
				token.includes("slide-in-from-top"),
		),
		exitX: tokens.some(
			(token) =>
				token.includes("slide-out-to-right") ||
				token.includes("slide-out-to-left"),
		),
		exitY: tokens.some(
			(token) =>
				token.includes("slide-out-to-bottom") ||
				token.includes("slide-out-to-top"),
		),
	};
}

const desktopWidthOverride =
	"max-h-[92svh] w-full max-w-none sm:max-h-none sm:w-[40rem] sm:max-w-[calc(100vw-2rem)] sm:rounded-none";

describe("responsive detail sheet motion", () => {
	const className = cn(
		sheetVariants({ side: "bottom-right" }),
		desktopWidthOverride,
	);

	it("slides only from the right on desktop", () => {
		expect(slideAxes(className, "desktop")).toEqual({
			enterX: true,
			enterY: false,
			exitX: true,
			exitY: false,
		});
	});

	it("slides only from the bottom on mobile", () => {
		expect(slideAxes(className, "mobile")).toEqual({
			enterX: false,
			enterY: true,
			exitX: false,
			exitY: true,
		});
	});
});

describe("single-side sheet motion", () => {
	it("keeps a bottom sheet on the Y axis at every viewport", () => {
		const className = sheetVariants({ side: "bottom" });
		expect(slideAxes(className, "desktop").enterX).toBe(false);
		expect(slideAxes(className, "desktop").enterY).toBe(true);
		expect(slideAxes(className, "mobile").enterY).toBe(true);
	});
});
