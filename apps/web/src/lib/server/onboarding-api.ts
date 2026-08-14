import { dev } from "$app/environment";
import { apiBaseUrl } from "$lib/server/api-client";

export const onboardingAcceptanceCookie = "_dhc_onboarding_acceptance";

type ReadableCookies = {
	get(name: string): string | undefined;
};

type WritableCookies = ReadableCookies & {
	set(
		name: string,
		value: string,
		options: {
			encode: (value: string) => string;
			httpOnly: boolean;
			maxAge: number;
			path: string;
			sameSite: "lax";
			secure: boolean;
		},
	): void;
};

export function onboardingApiClientOptions(cookies: ReadableCookies) {
	const proof = cookies.get(onboardingAcceptanceCookie);

	return {
		baseUrl: apiBaseUrl(),
		credentials: "include" as const,
		headers: proof
			? { cookie: `${onboardingAcceptanceCookie}=${proof}` }
			: undefined,
	};
}

export function relayOnboardingAcceptanceCookie(
	cookies: WritableCookies,
	headers: Headers,
	invitationId: string,
) {
	const setCookie = headers.get("set-cookie");
	const prefix = `${onboardingAcceptanceCookie}=`;
	const cookie = setCookie
		?.split(";")
		.map((part) => part.trim())
		.find((part) => part.startsWith(prefix));

	if (!cookie) return false;

	const value = cookie.slice(prefix.length);
	cookies.set(onboardingAcceptanceCookie, value, {
		encode: (raw) => raw,
		httpOnly: true,
		maxAge: 15 * 60,
		path: `/members/signup/${invitationId}`,
		sameSite: "lax",
		secure: !dev,
	});

	return true;
}
