/**
 * ALE-299: the real browser Push API behind the `PushBrowser` interface the
 * workflow uses. Browser-only; import from `onMount`/event handlers.
 */

import type { BrowserSubscription, PushBrowser } from "./workflow";

/**
 * Resolves the page's push manager, or `null` when there is no service
 * worker registration (the toggle then reports push as unsupported).
 */
export async function browserPushManager(): Promise<PushBrowser | null> {
	if (!("serviceWorker" in navigator)) return null;
	// `getRegistration` rather than `ready`: `ready` never settles when no
	// worker is registered, and the caller must be able to say so.
	const registration = await navigator.serviceWorker.getRegistration("/");
	if (!registration?.pushManager) return null;
	const pushManager = registration.pushManager;
	return {
		getSubscription: async () => {
			const subscription = await pushManager.getSubscription();
			return subscription ? adaptSubscription(subscription) : null;
		},
		subscribe: async (applicationServerKey) =>
			adaptSubscription(
				await pushManager.subscribe({
					userVisibleOnly: true,
					// SAFETY: a `Uint8Array` is a valid `applicationServerKey`; the
					// assertion only bridges TS 5.9's `ArrayBufferLike` generic to the
					// DOM's `BufferSource` alias.
					applicationServerKey: applicationServerKey as BufferSource,
				}),
			),
	};
}

// The DOM type declares `toJSON().endpoint` optional; the workflow needs the
// endpoint it can always read from the object itself.
function adaptSubscription(
	subscription: PushSubscription,
): BrowserSubscription {
	const key = subscription.options.applicationServerKey;
	return {
		endpoint: subscription.endpoint,
		applicationServerKey: key ? new Uint8Array(key) : null,
		toJSON: () => {
			const json = subscription.toJSON();
			return {
				endpoint: subscription.endpoint,
				expirationTime: json.expirationTime ?? null,
				keys:
					json.keys?.p256dh && json.keys.auth
						? { p256dh: json.keys.p256dh, auth: json.keys.auth }
						: undefined,
			};
		},
		unsubscribe: () => subscription.unsubscribe(),
	};
}
