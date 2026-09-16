import { describe, expect, it } from "vitest";
import { parsePushPayload, resolveClickTarget } from "./push";

describe("parsePushPayload", () => {
	it("reads the fields the server sends and keeps the notification id as the tag", () => {
		expect(
			parsePushPayload(
				JSON.stringify({
					title: "Dublin HEMA Club",
					body: "Your loan was approved",
					tag: "n-1",
					notificationId: "n-1",
					url: "/dashboard",
					createdAt: "2026-09-16T10:00:00Z",
				}),
			),
		).toEqual({
			title: "Dublin HEMA Club",
			body: "Your loan was approved",
			tag: "n-1",
			url: "/dashboard",
		});
	});

	it("falls back to a generic notification for an empty or malformed payload", () => {
		const fallback = {
			title: "Dublin HEMA Club",
			body: "You have a new notification.",
			tag: undefined,
			url: "/dashboard",
		};
		expect(parsePushPayload(null)).toEqual(fallback);
		expect(parsePushPayload("not json")).toEqual(fallback);
		expect(parsePushPayload(JSON.stringify({ body: 42 }))).toEqual(fallback);
	});

	it("only accepts same-origin relative urls as the click target", () => {
		// A payload can only come from our server, but the service worker is the
		// last line before `openWindow`, so an absolute URL is never trusted.
		expect(
			parsePushPayload(
				JSON.stringify({ body: "x", url: "https://evil.example/" }),
			).url,
		).toBe("/dashboard");
		expect(
			parsePushPayload(JSON.stringify({ body: "x", url: "//evil.example/" }))
				.url,
		).toBe("/dashboard");
		expect(
			parsePushPayload(JSON.stringify({ body: "x", url: "/inventory/loans" }))
				.url,
		).toBe("/inventory/loans");
	});
});

describe("resolveClickTarget", () => {
	const origin = "https://dashboard.example";

	it("focuses an already-open dashboard window and navigates it", () => {
		const target = resolveClickTarget(
			[
				{ url: "https://other.example/", focus: true },
				{ url: "https://dashboard.example/workshops", focus: true },
			],
			origin,
			"/inventory",
		);

		expect(target).toEqual({
			action: "focus",
			client: { url: "https://dashboard.example/workshops", focus: true },
			url: "https://dashboard.example/inventory",
		});
	});

	it("opens a new window when the dashboard is closed", () => {
		expect(resolveClickTarget([], origin, "/")).toEqual({
			action: "open",
			url: "https://dashboard.example/",
		});
	});

	it("skips clients that cannot be focused", () => {
		expect(
			resolveClickTarget(
				[{ url: "https://dashboard.example/", focus: false }],
				origin,
				"/",
			),
		).toEqual({ action: "open", url: "https://dashboard.example/" });
	});
});
