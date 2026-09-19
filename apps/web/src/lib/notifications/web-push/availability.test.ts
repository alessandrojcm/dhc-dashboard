import { describe, expect, it } from "vitest";
import {
	decidePushAvailability,
	type PushEnvironment,
	urlBase64ToUint8Array,
} from "./availability";

const capable: PushEnvironment = {
	serverEnabled: true,
	hasServiceWorker: true,
	hasPushManager: true,
	hasNotification: true,
	permission: "default",
	isIOS: false,
	isStandalone: false,
};

describe("decidePushAvailability", () => {
	it("is available when the browser and server both support push", () => {
		expect(decidePushAvailability(capable)).toEqual({
			kind: "available",
			permission: "default",
		});
		expect(
			decidePushAvailability({ ...capable, permission: "granted" }),
		).toEqual({ kind: "available", permission: "granted" });
	});

	it("reports a server without VAPID keys before looking at the browser", () => {
		expect(
			decidePushAvailability({
				...capable,
				serverEnabled: false,
				hasPushManager: false,
				permission: "denied",
			}),
		).toEqual({ kind: "server-disabled" });
	});

	it("tells iOS users in a browser tab to install the PWA first", () => {
		// iOS grants push only to installed web apps, so a tab is an install
		// problem, not an unsupported browser — even when a PushManager object
		// is present.
		expect(
			decidePushAvailability({
				...capable,
				isIOS: true,
				isStandalone: false,
				hasPushManager: false,
				permission: null,
			}),
		).toEqual({ kind: "ios-install-required" });
		expect(
			decidePushAvailability({ ...capable, isIOS: true, isStandalone: false }),
		).toEqual({ kind: "ios-install-required" });
	});

	it("treats an installed iOS PWA like any capable browser", () => {
		expect(
			decidePushAvailability({ ...capable, isIOS: true, isStandalone: true }),
		).toEqual({ kind: "available", permission: "default" });
	});

	it("is unsupported when any Push API piece is missing", () => {
		expect(
			decidePushAvailability({ ...capable, hasServiceWorker: false }),
		).toEqual({ kind: "unsupported" });
		expect(
			decidePushAvailability({ ...capable, hasPushManager: false }),
		).toEqual({ kind: "unsupported" });
		expect(
			decidePushAvailability({ ...capable, hasNotification: false }),
		).toEqual({ kind: "unsupported" });
	});

	it("explains a denial instead of offering to prompt again", () => {
		expect(
			decidePushAvailability({ ...capable, permission: "denied" }),
		).toEqual({ kind: "denied" });
	});
});

describe("urlBase64ToUint8Array", () => {
	it("decodes an unpadded base64url VAPID key into bytes", () => {
		// "BAEC" is base64 for 0x04 0x01 0x02; base64url with padding removed.
		expect(Array.from(urlBase64ToUint8Array("BAEC"))).toEqual([4, 1, 2]);
		// `-` / `_` are the url-safe alphabet for `+` / `/`.
		expect(Array.from(urlBase64ToUint8Array("-_8"))).toEqual([251, 255]);
	});
});
