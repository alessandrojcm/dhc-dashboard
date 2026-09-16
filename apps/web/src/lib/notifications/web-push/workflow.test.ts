import { describe, expect, it, vi } from "vitest";
import type { PushEnvironment } from "./availability";
import {
	determinePushStatus,
	disablePush,
	enablePush,
	forgetPushSubscription,
	type BrowserSubscription,
	type PushBrowser,
	type PushServer,
} from "./workflow";

const vapid = "BAEC";

const capableEnvironment = (serverEnabled: boolean): PushEnvironment => ({
	serverEnabled,
	hasServiceWorker: true,
	hasPushManager: true,
	hasNotification: true,
	permission: "default",
	isIOS: false,
	isStandalone: false,
});

function fakeSubscription(
	endpoint: string,
	applicationServerKey: Uint8Array | null = null,
): BrowserSubscription & {
	unsubscribe: ReturnType<typeof vi.fn>;
} {
	return {
		endpoint,
		applicationServerKey,
		toJSON: () => ({
			endpoint,
			expirationTime: null,
			keys: { p256dh: "p", auth: "a" },
		}),
		unsubscribe: vi.fn(async () => true),
	};
}

function fakeBrowser(
	existing: BrowserSubscription | null,
	subscribe: PushBrowser["subscribe"] = async () =>
		fakeSubscription("https://push.example/new"),
): PushBrowser {
	return {
		getSubscription: vi.fn(async () => existing),
		subscribe: vi.fn(subscribe),
	};
}

function fakeServer(
	overrides: Partial<PushServer> = {},
	enabled = true,
): PushServer {
	return {
		config: vi.fn(async () => ({
			enabled,
			vapidPublicKey: enabled ? vapid : null,
		})),
		register: vi.fn(async () => true),
		unregister: vi.fn(async () => true),
		...overrides,
	};
}

describe("determinePushStatus", () => {
	it("is off when the browser holds no subscription", async () => {
		const status = await determinePushStatus({
			browser: fakeBrowser(null),
			server: fakeServer(),
			environment: capableEnvironment,
			userAgent: "UA",
		});

		expect(status).toEqual({ kind: "off", vapidPublicKey: vapid });
	});

	it("is on and re-syncs an existing browser subscription to the server", async () => {
		const existing = fakeSubscription("https://push.example/existing");
		const server = fakeServer();

		const status = await determinePushStatus({
			browser: fakeBrowser(existing),
			server,
			environment: capableEnvironment,
			userAgent: "UA",
		});

		expect(status).toEqual({ kind: "on", vapidPublicKey: vapid });
		// The upsert keeps the server row bound to whoever is signed in on this
		// browser (a shared device) and repairs a row lost server-side.
		expect(server.register).toHaveBeenCalledWith(existing.toJSON(), "UA");
	});

	it("keeps a subscription created under the current VAPID key", async () => {
		const existing = fakeSubscription(
			"https://push.example/existing",
			new Uint8Array([4, 1, 2]),
		);

		const status = await determinePushStatus({
			browser: fakeBrowser(existing),
			server: fakeServer(),
			environment: capableEnvironment,
			userAgent: "UA",
		});

		expect(status).toEqual({ kind: "on", vapidPublicKey: vapid });
		expect(existing.unsubscribe).not.toHaveBeenCalled();
	});

	it("drops a subscription created under a rotated VAPID key and reports off", async () => {
		const stale = fakeSubscription(
			"https://push.example/stale",
			new Uint8Array([4, 9, 9]),
		);
		const server = fakeServer();

		const status = await determinePushStatus({
			browser: fakeBrowser(stale),
			server,
			environment: capableEnvironment,
			userAgent: "UA",
		});

		// The push service would refuse every send for the old key; a member who
		// sees "on" here would never learn why nothing arrives.
		expect(status).toEqual({ kind: "off", vapidPublicKey: vapid });
		expect(server.unregister).toHaveBeenCalledWith(
			"https://push.example/stale",
		);
		expect(stale.unsubscribe).toHaveBeenCalledTimes(1);
		expect(server.register).not.toHaveBeenCalled();
	});

	it("does not report on when the existing subscription cannot be confirmed server-side", async () => {
		const existing = fakeSubscription("https://push.example/existing");
		const server = fakeServer({ register: vi.fn(async () => false) });

		const status = await determinePushStatus({
			browser: fakeBrowser(existing),
			server,
			environment: capableEnvironment,
			userAgent: "UA",
		});

		// A browser subscription nothing will ever send to must not look enabled,
		// but the member must still be able to turn it off from the centre.
		expect(status).toMatchObject({ kind: "error", subscribed: true });
		expect(existing.unsubscribe).not.toHaveBeenCalled();
	});

	it("maps a server without keys, iOS tabs, unsupported browsers, and denials to their explanations", async () => {
		const server = fakeServer({}, false);
		expect(
			await determinePushStatus({
				browser: fakeBrowser(null),
				server,
				environment: capableEnvironment,
				userAgent: "UA",
			}),
		).toEqual({ kind: "server-disabled" });

		expect(
			await determinePushStatus({
				browser: null,
				server: fakeServer(),
				environment: (enabled) => ({
					...capableEnvironment(enabled),
					isIOS: true,
					hasPushManager: false,
				}),
				userAgent: "UA",
			}),
		).toEqual({ kind: "ios-install-required" });

		expect(
			await determinePushStatus({
				browser: null,
				server: fakeServer(),
				environment: (enabled) => ({
					...capableEnvironment(enabled),
					hasPushManager: false,
				}),
				userAgent: "UA",
			}),
		).toEqual({ kind: "unsupported" });

		expect(
			await determinePushStatus({
				browser: fakeBrowser(null),
				server: fakeServer(),
				environment: (enabled) => ({
					...capableEnvironment(enabled),
					permission: "denied",
				}),
				userAgent: "UA",
			}),
		).toEqual({ kind: "denied" });
	});

	it("is unsupported when the page has no service worker registration", async () => {
		expect(
			await determinePushStatus({
				browser: null,
				server: fakeServer(),
				environment: capableEnvironment,
				userAgent: "UA",
			}),
		).toEqual({ kind: "unsupported" });
	});

	it("reports an error when the server config cannot be read", async () => {
		const status = await determinePushStatus({
			browser: fakeBrowser(null),
			server: fakeServer({ config: vi.fn(async () => null) }),
			environment: capableEnvironment,
			userAgent: "UA",
		});

		expect(status.kind).toBe("error");
	});
});

describe("enablePush", () => {
	it("subscribes the browser with the VAPID key and registers it server-side", async () => {
		const created = fakeSubscription("https://push.example/new");
		const subscribe = vi.fn(async (_key: Uint8Array) => created);
		const browser = fakeBrowser(null, subscribe);
		const server = fakeServer();

		const status = await enablePush({
			browser,
			server,
			vapidPublicKey: vapid,
			userAgent: "UA",
		});

		expect(status).toEqual({ kind: "on", vapidPublicKey: vapid });
		expect(subscribe).toHaveBeenCalledTimes(1);
		const [key] = subscribe.mock.calls[0] ?? [];
		expect(key ? Array.from(key) : null).toEqual([4, 1, 2]);
		expect(server.register).toHaveBeenCalledWith(created.toJSON(), "UA");
	});

	it("rolls the browser subscription back when the server refuses it", async () => {
		const created = fakeSubscription("https://push.example/new");
		const browser = fakeBrowser(null, async () => created);
		const server = fakeServer({ register: vi.fn(async () => false) });

		const status = await enablePush({
			browser,
			server,
			vapidPublicKey: vapid,
			userAgent: "UA",
		});

		expect(status.kind).toBe("error");
		// Otherwise the browser would keep a subscription nothing ever sends to.
		expect(created.unsubscribe).toHaveBeenCalledTimes(1);
	});

	it("turns a permission refusal into the denied explanation, not an error", async () => {
		const browser = fakeBrowser(null, async () => {
			throw new DOMException("denied", "NotAllowedError");
		});

		const status = await enablePush({
			browser,
			server: fakeServer(),
			vapidPublicKey: vapid,
			userAgent: "UA",
		});

		expect(status).toEqual({ kind: "denied" });
	});

	it("reports other subscribe failures as errors without touching the server", async () => {
		const server = fakeServer();
		const browser = fakeBrowser(null, async () => {
			throw new Error("push service unreachable");
		});

		const status = await enablePush({
			browser,
			server,
			vapidPublicKey: vapid,
			userAgent: "UA",
		});

		expect(status.kind).toBe("error");
		expect(server.register).not.toHaveBeenCalled();
	});
});

describe("disablePush", () => {
	it("removes the server row first, then the browser subscription", async () => {
		const existing = fakeSubscription("https://push.example/existing");
		const order: string[] = [];
		const unregister = vi.fn(async (_endpoint: string) => {
			order.push("server");
			return true;
		});
		const server = fakeServer({ unregister });
		existing.unsubscribe.mockImplementation(async () => {
			order.push("browser");
			return true;
		});

		const status = await disablePush({
			browser: fakeBrowser(existing),
			server,
			vapidPublicKey: vapid,
		});

		expect(status).toEqual({ kind: "off", vapidPublicKey: vapid });
		expect(unregister).toHaveBeenCalledWith("https://push.example/existing");
		expect(order).toEqual(["server", "browser"]);
	});

	it("is off already when the browser has no subscription", async () => {
		const server = fakeServer();

		const status = await disablePush({
			browser: fakeBrowser(null),
			server,
			vapidPublicKey: vapid,
		});

		expect(status).toEqual({ kind: "off", vapidPublicKey: vapid });
		expect(server.unregister).not.toHaveBeenCalled();
	});

	it("still drops the browser subscription when the server call fails", async () => {
		const existing = fakeSubscription("https://push.example/existing");
		const server = fakeServer({ unregister: vi.fn(async () => false) });

		const status = await disablePush({
			browser: fakeBrowser(existing),
			server,
			vapidPublicKey: vapid,
		});

		// The member asked for silence on this device; a dead row server-side
		// is cleaned up by the push service's 410 on the next delivery.
		expect(status).toEqual({ kind: "off", vapidPublicKey: vapid });
		expect(existing.unsubscribe).toHaveBeenCalledTimes(1);
	});
});

describe("forgetPushSubscription", () => {
	it("removes the server row and the browser subscription at sign-out", async () => {
		const existing = fakeSubscription("https://push.example/existing");
		const server = fakeServer();

		await forgetPushSubscription({ browser: fakeBrowser(existing), server });

		expect(server.unregister).toHaveBeenCalledWith(
			"https://push.example/existing",
		);
		expect(existing.unsubscribe).toHaveBeenCalledTimes(1);
	});

	it("is a no-op without a service worker or a subscription", async () => {
		const server = fakeServer();

		await forgetPushSubscription({ browser: null, server });
		await forgetPushSubscription({ browser: fakeBrowser(null), server });

		expect(server.unregister).not.toHaveBeenCalled();
	});
});
