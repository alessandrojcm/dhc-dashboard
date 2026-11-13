/**
 * Which venue lookup a destination input searches through (ALE-442).
 *
 * Production inputs use the one remote boundary (`remoteVenueLookup`). A
 * surface that renders the input may provide another implementation of the
 * same `VenueLookup` interface through Svelte context — form tests do, so
 * they exercise real form submissions without reaching Phoenix or Google.
 */
import { getContext } from "svelte";
import type { VenueLookup } from "#lib/venue-lookup/venue-lookup.js";
import {
	resolveVenue,
	suggestVenues,
} from "#lib/venue-lookup/venue-lookup.remote.js";

/** The context key a provided `VenueLookup` is stored under. */
export const VENUE_LOOKUP_CONTEXT = Symbol("venue-lookup");

/** The remote boundary: Phoenix's `Dhc.Places` through remote commands. */
export const remoteVenueLookup: VenueLookup = {
	suggest: (input, sessionToken) => suggestVenues({ input, sessionToken }),
	resolve: (placeId, sessionToken) => resolveVenue({ placeId, sessionToken }),
};

/** The provided lookup, else the remote boundary. Call during init. */
export function currentVenueLookup(): VenueLookup {
	return (
		getContext<VenueLookup | undefined>(VENUE_LOOKUP_CONTEXT) ??
		remoteVenueLookup
	);
}
