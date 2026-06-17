import { env } from "$env/dynamic/private";
import type { Session } from "@supabase/supabase-js";

const DEFAULT_API_BASE_URL = "http://localhost:4000/api";

export function apiBaseUrl(): string {
	return env.API_BASE_URL ?? DEFAULT_API_BASE_URL;
}

export function apiClientOptions(session: Pick<Session, "access_token">) {
	return {
		baseUrl: apiBaseUrl(),
		auth: session.access_token,
	};
}
