/**
 * ALE-381: keeps Intake link tokens out of logs, Sentry and analytics. The
 * person's Intake page lives at `/beginners/intake/<token>` (Phoenix's
 * endpoints at `/api/beginners/intake/<token>`), and the token is the only
 * credential, so every URL or path we record goes through here first. The
 * Phoenix twin is `DhcWeb.IntakeLinkPrivacy`.
 */

const SEGMENT = /(beginners\/intake\/)[^/?#\s"'\\]+/g;
export const REDACTED = "[REDACTED]";

/** Replaces every Intake link token in `text`. */
export function redactIntakeLinks(text: string): string {
	return text.replace(SEGMENT, `$1${REDACTED}`);
}

/**
 * A copy of a JSON-shaped payload (a Sentry event, transaction or
 * breadcrumb, a PostHog event) with every Intake link token redacted,
 * wherever its integrations put the URL. Returns `null` — drop the payload —
 * when it cannot be serialised, because sending it unredacted would leak.
 */
export function redactPayload<Payload extends object>(
	payload: Payload,
): Payload | null {
	let json: string;
	try {
		json = JSON.stringify(payload);
	} catch {
		return null;
	}
	// SAFETY: `json` is `payload` serialised; redaction only rewrites the
	// contents of string literals (the pattern stops at a quote or a
	// backslash), so parsing it back yields the same JSON shape.
	return JSON.parse(redactIntakeLinks(json)) as Payload;
}

/**
 * `redactPayload` for a Sentry event or transaction. Sentry strips
 * `sdkProcessingMetadata` before sending; it holds live scopes, so it is
 * carried over untouched instead of serialised.
 */
export function redactSentryEvent<
	Event extends { sdkProcessingMetadata?: object },
>(event: Event): Event | null {
	const { sdkProcessingMetadata, ...sent } = event;
	const redacted = redactPayload(sent);
	if (!redacted) return null;
	return sdkProcessingMetadata === undefined
		? { ...event, ...redacted }
		: { ...event, ...redacted, sdkProcessingMetadata };
}

/**
 * Sentry's `beforeSendSpan` must return a span. A span is plain attribute
 * data (never cyclic), so it always serialises; were it not to, it is sent
 * as it is rather than breaking the span tree.
 */
export function redactSentrySpan<Span extends object>(span: Span): Span {
	return redactPayload(span) ?? span;
}
