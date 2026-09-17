/**
 * ALE-299: the enable / disable / status workflow for Web Push, with the
 * browser Push API and the Phoenix API behind two small interfaces so the
 * decisions are unit-tested without a service worker or a network.
 *
 * Phoenix stays authoritative for *who* gets pushed; the browser is
 * authoritative for whether *this installation* holds a subscription. The
 * toggle therefore reads its on/off state from `PushManager.getSubscription`
 * and treats the server row as something to keep in sync with it.
 */

import * as v from "valibot";
import {
	decidePushAvailability,
	type PushEnvironment,
	urlBase64ToUint8Array,
} from "./availability";

// `PushManager.subscribe` rejects with a `NotAllowedError` DOMException when
// the member declines the permission prompt (or the browser auto-declines).
const permissionRefusalSchema = v.object({
	name: v.literal("NotAllowedError"),
});

/** `PushSubscription.toJSON()` as the browser serialises it. */
export type BrowserSubscriptionJSON = {
	endpoint: string;
	expirationTime?: number | null;
	keys?: { p256dh: string; auth: string };
};

export interface BrowserSubscription {
	readonly endpoint: string;
	/** The VAPID key this subscription was created with, when the browser reports it. */
	readonly applicationServerKey: Uint8Array | null;
	toJSON(): BrowserSubscriptionJSON;
	unsubscribe(): Promise<boolean>;
}

/** The slice of `ServiceWorkerRegistration.pushManager` the workflow uses. */
export interface PushBrowser {
	getSubscription(): Promise<BrowserSubscription | null>;
	subscribe(applicationServerKey: Uint8Array): Promise<BrowserSubscription>;
}

export type PushServerConfig = {
	enabled: boolean;
	vapidPublicKey: string | null;
};

/** The three `notificationsPush.*` operations; `null`/`false` mean failure. */
export interface PushServer {
	config(): Promise<PushServerConfig | null>;
	register(
		subscription: BrowserSubscriptionJSON,
		userAgent: string,
	): Promise<boolean>;
	unregister(endpoint: string): Promise<boolean>;
}

export type PushStatus =
	| { kind: "loading" }
	| { kind: "server-disabled" }
	| { kind: "ios-install-required" }
	| { kind: "unsupported" }
	| { kind: "denied" }
	| { kind: "off"; vapidPublicKey: string; warning?: string }
	| { kind: "on"; vapidPublicKey: string }
	| {
			kind: "error";
			message: string;
			vapidPublicKey: string | null;
			/** The browser still holds a subscription the member may want to drop. */
			subscribed: boolean;
	  };

export async function determinePushStatus(input: {
	/** `null` when the page has no service worker registration. */
	browser: PushBrowser | null;
	server: PushServer;
	environment: (serverEnabled: boolean) => PushEnvironment;
	userAgent: string;
}): Promise<PushStatus> {
	const config = await input.server.config();
	if (!config) {
		return {
			kind: "error",
			message: "Couldn't check push notification settings.",
			vapidPublicKey: null,
			subscribed: false,
		};
	}

	const availability = decidePushAvailability(
		input.environment(config.enabled),
	);
	if (availability.kind !== "available") return availability;
	if (!config.vapidPublicKey) return { kind: "server-disabled" };
	if (!input.browser) return { kind: "unsupported" };

	const vapidPublicKey = config.vapidPublicKey;
	const existing = await input.browser.getSubscription().catch(() => null);
	if (!existing) return { kind: "off", vapidPublicKey };

	// A subscription created under a previous VAPID key can never be sent to
	// again (the push service checks the key on every request). Drop it and
	// report "off" so the member can opt in again under the current key.
	if (!subscribedWithKey(existing, vapidPublicKey)) {
		await forgetPushSubscription({
			browser: input.browser,
			server: input.server,
		});
		return { kind: "off", vapidPublicKey };
	}

	// Re-register on every load: an upsert on the endpoint, so it is free when
	// nothing changed, rebinds a shared device to whoever is signed in now, and
	// repairs a server row that was lost. Only a confirmed row is "on" — a
	// browser subscription nothing will ever send to must not look enabled.
	const confirmed = await input.server
		.register(existing.toJSON(), input.userAgent)
		.catch(() => false);
	if (!confirmed) {
		return {
			kind: "error",
			message: "Couldn't confirm this device for push notifications.",
			vapidPublicKey,
			subscribed: true,
		};
	}

	return { kind: "on", vapidPublicKey };
}

// Browsers that report the key let us detect rotation; one that reports
// `null` (older WebKit) is trusted as-is.
function subscribedWithKey(
	subscription: BrowserSubscription,
	vapidPublicKey: string,
): boolean {
	if (!subscription.applicationServerKey) return true;
	const expected = urlBase64ToUint8Array(vapidPublicKey);
	const actual = subscription.applicationServerKey;
	return (
		actual.length === expected.length &&
		actual.every((byte, index) => byte === expected[index])
	);
}

export async function enablePush(input: {
	browser: PushBrowser;
	server: PushServer;
	vapidPublicKey: string;
	userAgent: string;
}): Promise<PushStatus> {
	let subscription: BrowserSubscription;
	try {
		// This is the one call that may show the permission prompt; it only ever
		// runs from the member's click on the toggle.
		subscription = await input.browser.subscribe(
			urlBase64ToUint8Array(input.vapidPublicKey),
		);
	} catch (error) {
		if (v.safeParse(permissionRefusalSchema, error).success) {
			return { kind: "denied" };
		}
		return {
			kind: "error",
			message: "Couldn't turn on push notifications in this browser.",
			vapidPublicKey: input.vapidPublicKey,
			subscribed: false,
		};
	}

	const registered = await input.server
		.register(subscription.toJSON(), input.userAgent)
		.catch(() => false);

	if (!registered) {
		// Without the server row nothing will ever be sent here; do not leave the
		// browser believing it is subscribed.
		await subscription.unsubscribe().catch(() => false);
		return {
			kind: "error",
			message: "Couldn't save this device for push notifications.",
			vapidPublicKey: input.vapidPublicKey,
			subscribed: false,
		};
	}

	return { kind: "on", vapidPublicKey: input.vapidPublicKey };
}

export async function disablePush(input: {
	browser: PushBrowser;
	server: PushServer;
	vapidPublicKey: string;
}): Promise<PushStatus> {
	const { browserGone, serverUnregistered } =
		await forgetPushSubscription(input);

	if (!browserGone) {
		return {
			kind: "error",
			message: "Couldn't turn off push notifications in this browser.",
			vapidPublicKey: input.vapidPublicKey,
			subscribed: true,
		};
	}

	if (!serverUnregistered) {
		return {
			kind: "off",
			vapidPublicKey: input.vapidPublicKey,
			warning:
				"Couldn't remove this device from the server. This device will stay quiet.",
		};
	}

	return { kind: "off", vapidPublicKey: input.vapidPublicKey };
}

export type ForgetPushResult = {
	/** True when this browser no longer holds a subscription. */
	browserGone: boolean;
	/** True when the server row is gone, or there was nothing to remove. */
	serverUnregistered: boolean;
};

/**
 * Drops this browser's subscription on both sides, best-effort. Used by the
 * toggle's "off" and by sign-out: a shared device must stop receiving the
 * departing member's notifications, and the server row can only be removed
 * while their session cookie is still valid.
 *
 * `off` is only honest when the browser subscription is gone (unsubscribe
 * succeeded, or there was none). A failed server unregister still leaves
 * the device quiet (the stale row dies on the next 404/410). A failed
 * `getSubscription` or `unsubscribe` does not — those are not proof gone.
 */
export async function forgetPushSubscription(input: {
	browser: PushBrowser | null;
	server: Pick<PushServer, "unregister">;
}): Promise<ForgetPushResult> {
	if (!input.browser) {
		return { browserGone: true, serverUnregistered: true };
	}

	let existing: BrowserSubscription | null;
	try {
		existing = await input.browser.getSubscription();
	} catch {
		// A lookup failure is not proof the subscription is gone.
		return { browserGone: false, serverUnregistered: false };
	}
	if (!existing) {
		return { browserGone: true, serverUnregistered: true };
	}

	// Server first, while we still hold the endpoint that names the row. If it
	// fails the row goes stale and the push service's 404/410 removes it on the
	// next delivery; the member's device goes quiet either way.
	const serverUnregistered = await input.server
		.unregister(existing.endpoint)
		.catch(() => false);
	const unsubscribed = await existing.unsubscribe().catch(() => false);
	return { browserGone: unsubscribed, serverUnregistered };
}
