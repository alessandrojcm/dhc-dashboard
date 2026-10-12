import { afterAll, beforeAll, expect } from "vitest";
import { cdp } from "vitest/browser";

/**
 * Runs the rest of a browser test file with Chromium's own clock in
 * `timeZone`, so a component that silently reads the reader's zone shows the
 * shift. The override lives on the browser page, which Vitest reuses for the
 * session's next test file, so it is always cleared afterwards.
 */
export function onHostTimeZone(timeZone: string) {
	beforeAll(async () => {
		await cdp().send("Emulation.setTimezoneOverride", { timezoneId: timeZone });
		// Guards the file: without it, an ignored override would pass for the
		// wrong reason.
		expect(Intl.DateTimeFormat().resolvedOptions().timeZone).toBe(timeZone);
	});

	afterAll(async () => {
		await cdp().send("Emulation.setTimezoneOverride", { timezoneId: "" });
	});
}
