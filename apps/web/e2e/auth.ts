import type { BrowserContext } from "@playwright/test";
import { fetchE2EHarness } from "./e2eApi";

export async function loginAsUser(context: BrowserContext, email: string) {
	const response = await fetchE2EHarness(
		"/login",
		{
			method: "POST",
			body: JSON.stringify({ email }),
		},
		true,
	);

	if (!response.ok) {
		throw new Error(
			`Phoenix E2E login failed (${response.status}): ${await response.text()}`,
		);
	}

	const setCookie = response.headers.get("set-cookie");
	const cookieValue = /_dhc_session=([^;]+)/.exec(setCookie ?? "")?.[1];
	if (!cookieValue)
		throw new Error("Phoenix E2E login did not return _dhc_session");

	await context.addCookies([
		{
			name: "_dhc_session",
			value: cookieValue,
			domain: "127.0.0.1",
			path: "/",
			httpOnly: true,
			secure: false,
			sameSite: "Lax",
		},
	]);
}
