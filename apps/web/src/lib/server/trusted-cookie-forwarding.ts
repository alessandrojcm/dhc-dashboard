import type { Cookies } from "@sveltejs/kit";

export type CookieWriter = Pick<Cookies, "set">;

type CookieOptions = Parameters<Cookies["set"]>[2];

const cookieNamePattern = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
const cookieValuePattern = /^[\u0021-\u003A\u003C-\u007E]*$/;
const cookiePathPattern = /^[\u0020-\u003A\u003D-\u007E]+$/;
const cookieDomainPattern = /^\.?[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$/;

/**
 * Forward every cookie from a trusted upstream response onto the SvelteKit
 * response. This is transport-only: cookie names and lifecycle policy remain
 * owned by Phoenix and its callers.
 */
export function forwardTrustedResponseCookies(
	cookies: CookieWriter,
	headers: Headers,
): string[] {
	const forwarded: string[] = [];

	for (const header of setCookieHeaders(headers)) {
		const parsed = parseTrustedSetCookie(header);
		if (!parsed) continue;

		cookies.set(parsed.name, parsed.value, parsed.options);
		forwarded.push(parsed.name);
	}

	return forwarded;
}

/** Read one named cookie from a trusted upstream response without applying it. */
export function trustedResponseCookie(headers: Headers, name: string) {
	for (const header of setCookieHeaders(headers)) {
		const parsed = parseTrustedSetCookie(header);
		if (parsed?.name === name) return parsed;
	}

	return undefined;
}

export function forwardTrustedResponseCookie(
	cookies: CookieWriter,
	headers: Headers,
	name: string,
): boolean {
	const parsed = trustedResponseCookie(headers, name);
	if (!parsed) return false;

	cookies.set(parsed.name, parsed.value, parsed.options);
	return true;
}

function setCookieHeaders(headers: Headers): string[] {
	const values = headers.getSetCookie();
	if (values.length > 0) {
		return values.flatMap(splitCombinedSetCookieHeader);
	}

	const combined = headers.get("set-cookie");
	return combined ? splitCombinedSetCookieHeader(combined) : [];
}

function splitCombinedSetCookieHeader(header: string): string[] {
	const cookies: string[] = [];
	let start = 0;

	for (let index = 0; index < header.length; index += 1) {
		if (header[index] !== ",") continue;

		const remainder = header.slice(index + 1);
		if (!/^\s*[!#$%&'*+\-.^_`|~0-9A-Za-z]+\s*=/.test(remainder)) continue;

		cookies.push(header.slice(start, index).trim());
		start = index + 1;
	}

	cookies.push(header.slice(start).trim());
	return cookies.filter(Boolean);
}

function parseTrustedSetCookie(
	header: string,
): { name: string; value: string; options: CookieOptions } | undefined {
	const [nameValue, ...attributeParts] = header.split(";");
	const equalsIndex = nameValue.indexOf("=");
	if (equalsIndex < 1) return undefined;

	const name = nameValue.slice(0, equalsIndex).trim();
	if (!cookieNamePattern.test(name)) return undefined;

	const value = nameValue.slice(equalsIndex + 1).trim();
	if (!cookieValuePattern.test(value)) return undefined;

	const options: Omit<CookieOptions, "path"> = {
		encode: (raw) => raw,
		httpOnly: false,
		sameSite: false,
		secure: false,
	};
	let path: string | undefined;

	for (const part of attributeParts) {
		const attribute = part.trim();
		const attributeEqualsIndex = attribute.indexOf("=");
		const key = (
			attributeEqualsIndex === -1
				? attribute
				: attribute.slice(0, attributeEqualsIndex)
		).toLowerCase();
		const attributeValue =
			attributeEqualsIndex === -1
				? undefined
				: attribute.slice(attributeEqualsIndex + 1).trim();

		switch (key) {
			case "httponly":
				options.httpOnly = true;
				break;
			case "secure":
				options.secure = true;
				break;
			case "samesite": {
				const sameSite = attributeValue?.toLowerCase();
				if (
					sameSite === "lax" ||
					sameSite === "strict" ||
					sameSite === "none"
				) {
					options.sameSite = sameSite;
				}
				break;
			}
			case "path":
				if (attributeValue && cookiePathPattern.test(attributeValue)) {
					path = attributeValue;
				}
				break;
			case "max-age": {
				if (attributeValue && /^-?\d+$/.test(attributeValue)) {
					const maxAge = Number(attributeValue);
					if (Number.isFinite(maxAge)) options.maxAge = maxAge;
				}
				break;
			}
			case "expires": {
				if (!attributeValue) break;
				const expires = new Date(attributeValue);
				if (!Number.isNaN(expires.getTime())) options.expires = expires;
				break;
			}
			case "domain":
				if (attributeValue && cookieDomainPattern.test(attributeValue)) {
					options.domain = attributeValue;
				}
				break;
		}
	}

	if (!path) return undefined;
	return { name, value, options: { ...options, path } };
}
