import type { BrowserContext } from "@playwright/test";
import { API_BASE_URL, HARNESS_KEY } from "./e2eApi";

export async function loginAsUser(context: BrowserContext, email: string) {
	const response = await fetch(`${API_BASE_URL}/e2e/login`, {
		method: "POST",
		headers: {
			"content-type": "application/json",
			"x-e2e-harness-key": HARNESS_KEY,
		},
		body: JSON.stringify({ email }),
	});

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
