/**
 * ALE-299: the decisions the service worker makes for a push message, kept
 * free of worker globals so they run under plain Vitest.
 *
 * The worker itself (`src/service-worker.ts`) only wires events to these:
 * `push` → `parsePushPayload` → `showNotification`, `notificationclick` →
 * `resolveClickTarget` → focus-or-open.
 */

import * as v from "valibot";

export const DEFAULT_TITLE = "Dublin HEMA Club";
const DEFAULT_BODY = "You have a new notification.";
/** Where a click lands when the payload names nothing valid: the dashboard, not the empty root page. */
export const DEFAULT_URL = "/dashboard";

export type PushDisplay = {
	title: string;
	body: string;
	/** The notification id, so a re-sent push replaces rather than stacks. */
	tag: string | undefined;
	/** Same-origin path to open on click. */
	url: string;
};

// What the server sends (`Dhc.Notifications.WebPush.payload/1`), with every
// field optional so a partial or older payload still displays something.
const pushPayloadSchema = v.object({
	title: v.optional(v.string()),
	body: v.string(),
	tag: v.optional(v.string()),
	url: v.optional(v.string()),
});

export function parsePushPayload(text: string | null): PushDisplay {
	const fallback: PushDisplay = {
		title: DEFAULT_TITLE,
		body: DEFAULT_BODY,
		tag: undefined,
		url: DEFAULT_URL,
	};
	if (!text) return fallback;

	let json: unknown;
	try {
		json = JSON.parse(text);
	} catch {
		return fallback;
	}

	const parsed = v.safeParse(pushPayloadSchema, json);
	if (!parsed.success) return fallback;

	return {
		title: parsed.output.title ?? DEFAULT_TITLE,
		body: parsed.output.body,
		tag: parsed.output.tag,
		url: sameOriginPath(parsed.output.url ?? DEFAULT_URL),
	};
}

// Only a path is honoured: `//host`, `scheme://host`, and a backslash
// (WHATWG treats `\` as `/`, so `/\evil.example` becomes `//evil.example`)
// are rejected so a payload can never make the worker open another origin.
export function sameOriginPath(value: string): string {
	if (
		!value.startsWith("/") ||
		value.startsWith("//") ||
		value.includes("\\")
	) {
		return DEFAULT_URL;
	}
	return value;
}

export type FocusableClient = {
	readonly url: string;
	/** `false` when the client cannot be focused (e.g. a non-window client). */
	readonly focus: unknown;
};

export type ClickTarget<C extends FocusableClient> =
	| { action: "focus"; client: C; url: string }
	| { action: "open"; url: string };

export function resolveClickTarget<C extends FocusableClient>(
	clients: readonly C[],
	origin: string,
	path: string,
): ClickTarget<C> {
	const resolved = new URL(path, origin);
	const url =
		resolved.origin === origin
			? resolved.toString()
			: new URL(DEFAULT_URL, origin).toString();
	const open = clients.find(
		(client) => client.url.startsWith(origin) && Boolean(client.focus),
	);
	if (open) return { action: "focus", client: open, url };
	return { action: "open", url };
}
