import { jwtDecode } from "jwt-decode";
import * as Sentry from "@sentry/deno";

export function getRolesFromSession(accessToken: string) {
	try {
		const tokenClaim = jwtDecode(accessToken);
		console.log(tokenClaim);
		return new Set(
			(tokenClaim as { app_metadata: { roles: string[] } }).app_metadata
				?.roles || [],
		);
	} catch (error) {
		Sentry.captureMessage(`Error decoding token: ${error}`, "error");
		return new Set();
	}
}
