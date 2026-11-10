/**
 * ALE-442: the browser's one route to Google venue search — thin adapters
 * over Phoenix's `Dhc.Places` lookup (`venueLookup.*`). They check the
 * `venues.lookup` capability, make one generated call and answer a closed
 * result whose failure is Phoenix's worded `detail`, so an unconfigured,
 * over-quota or unavailable Google never blocks manual entry. They write
 * nothing, keep nothing and never log the search.
 */
import { command, getRequestEvent } from "$app/server";
import { venueLookupResolve, venueLookupSuggest } from "@dhc/api-client";
import * as v from "valibot";
import { commandResult } from "#lib/server/api/command-result.js";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorize } from "#lib/server/auth.js";
import {
	LOOKUP_UNAVAILABLE,
	type LookupResult,
	VENUE_SEARCH_MAX,
	type VenueSelection,
	type VenueSuggestion,
} from "#lib/venue-lookup/venue-lookup.js";

const sessionToken = v.pipe(v.string(), v.uuid());

const suggestSchema = v.object({
	input: v.pipe(
		v.string(),
		v.trim(),
		v.nonEmpty(),
		v.maxLength(VENUE_SEARCH_MAX),
	),
	sessionToken,
});

const resolveSchema = v.object({
	placeId: v.pipe(v.string(), v.regex(/^[A-Za-z0-9_-]{1,255}$/)),
	sessionToken,
});

const noFields = () => ({ issues: [], unattributed: false });

async function lookupOptions() {
	const event = getRequestEvent();
	await authorize(event.locals, "venues.lookup");
	return apiClientOptions(event.cookies);
}

export const suggestVenues = command(
	suggestSchema,
	async ({ input, sessionToken }): Promise<LookupResult<VenueSuggestion[]>> => {
		const options = await lookupOptions();
		const result = await commandResult(
			venueLookupSuggest({ ...options, body: { input, sessionToken } }),
			LOOKUP_UNAVAILABLE,
			noFields,
		);
		return result.ok
			? { ok: true, data: result.data.suggestions }
			: { ok: false, error: result.error };
	},
);

export const resolveVenue = command(
	resolveSchema,
	async ({ placeId, sessionToken }): Promise<LookupResult<VenueSelection>> => {
		const options = await lookupOptions();
		const result = await commandResult(
			venueLookupResolve({ ...options, body: { placeId, sessionToken } }),
			LOOKUP_UNAVAILABLE,
			noFields,
		);
		return result.ok
			? { ok: true, data: result.data }
			: { ok: false, error: result.error };
	},
);
