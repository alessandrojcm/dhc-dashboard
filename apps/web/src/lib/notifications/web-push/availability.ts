/**
 * ALE-299: decides whether this browser can offer Web Push, and why not.
 *
 * Pure: every environment fact is passed in, so the decision is unit-tested
 * without a browser and the component only has to read the facts. The order
 * of the checks is the user-facing explanation order — a server without keys
 * is the deployment's problem, an iOS browser tab is an install problem, a
 * missing API is a browser problem, and a denial is a permission the user
 * changed and must change back themselves (we never prompt again).
 */

export type PushEnvironment = {
	/** `GET /notifications/push/config` said push is configured. */
	serverEnabled: boolean;
	hasServiceWorker: boolean;
	hasPushManager: boolean;
	hasNotification: boolean;
	permission: NotificationPermission | null;
	isIOS: boolean;
	/** Running as an installed web app (standalone display mode). */
	isStandalone: boolean;
};

export type PushAvailability =
	| { kind: "server-disabled" }
	| { kind: "ios-install-required" }
	| { kind: "unsupported" }
	| { kind: "denied" }
	| { kind: "available"; permission: "default" | "granted" };

export function decidePushAvailability(env: PushEnvironment): PushAvailability {
	if (!env.serverEnabled) return { kind: "server-disabled" };

	// iOS grants Web Push only to web apps added to the Home Screen, whatever
	// the browser and whether or not a PushManager object happens to exist in
	// the tab. The fix is to install, not to switch browser.
	if (env.isIOS && !env.isStandalone) {
		return { kind: "ios-install-required" };
	}

	if (!env.hasServiceWorker || !env.hasPushManager || !env.hasNotification) {
		return { kind: "unsupported" };
	}

	if (env.permission === "denied") return { kind: "denied" };

	return {
		kind: "available",
		permission: env.permission === "granted" ? "granted" : "default",
	};
}

/**
 * Reads the environment facts from a window. Split from the decision so the
 * decision stays pure; kept tolerant because feature detection runs before we
 * know anything about the browser.
 */
export function readPushEnvironment(
	win: Window & typeof globalThis,
	serverEnabled: boolean,
): PushEnvironment {
	const nav = win.navigator;
	const ua = nav.userAgent ?? "";
	// iPadOS reports a Mac UA; touch points tell it apart from a real Mac.
	const isIOS =
		/iPad|iPhone|iPod/.test(ua) ||
		(nav.platform === "MacIntel" && (nav.maxTouchPoints ?? 0) > 1);
	// SAFETY: `navigator.standalone` is a non-standard iOS Safari property the
	// DOM lib does not declare; it is read with optional chaining and compared
	// to `true`, so an absent property is simply "not standalone".
	const standaloneNavigator = nav as Navigator & { standalone?: boolean };
	const isStandalone =
		win.matchMedia?.("(display-mode: standalone)").matches === true ||
		standaloneNavigator.standalone === true;

	return {
		serverEnabled,
		hasServiceWorker: "serviceWorker" in nav,
		hasPushManager: "PushManager" in win,
		hasNotification: "Notification" in win,
		permission: "Notification" in win ? win.Notification.permission : null,
		isIOS,
		isStandalone,
	};
}

/**
 * `PushManager.subscribe` wants the VAPID public key as bytes on Safari
 * (Chromium also accepts the string). The server hands it out as unpadded
 * base64url.
 */
export function urlBase64ToUint8Array(base64Url: string): Uint8Array {
	const padding = "=".repeat((4 - (base64Url.length % 4)) % 4);
	const base64 = (base64Url + padding).replace(/-/g, "+").replace(/_/g, "/");
	const raw = atob(base64);
	const bytes = new Uint8Array(raw.length);
	for (let i = 0; i < raw.length; i += 1) bytes[i] = raw.charCodeAt(i);
	return bytes;
}
