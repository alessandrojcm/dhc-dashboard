/**
 * The domain-neutral venue lookup vocabulary (ALE-442).
 *
 * Every Workshop form's destination input searches Google Maps through one
 * boundary — `venue-lookup.remote.ts`, which calls Phoenix's `Dhc.Places` —
 * and never writes a workshop: a chosen place only fills the form, which
 * saves it through its own domain's operation. Suggestions and previews are
 * transient: nothing here caches, persists or reports them.
 */
import type { DestinationCredit } from "#lib/destinations.js";

/** One Google suggestion, for the current search only. */
export interface VenueSuggestion {
	placeId: string;
	text: string;
}

/** The closed preview of a deliberately chosen suggestion. */
export interface VenueSelection {
	provider: "google";
	placeId: string;
	name: string | null;
	address: string | null;
	attributions: DestinationCredit[];
}

/** A lookup answer: the data, or the sentence to show beside the search. */
export type LookupResult<Data> =
	| { ok: true; data: Data }
	| { ok: false; error: string };

/**
 * The one lookup boundary the search controller talks to; form tests
 * substitute it.
 */
export interface VenueLookup {
	suggest(
		input: string,
		sessionToken: string,
	): Promise<LookupResult<VenueSuggestion[]>>;
	resolve(
		placeId: string,
		sessionToken: string,
	): Promise<LookupResult<VenueSelection>>;
}

/** The longest search Phoenix accepts (`Dhc.Places.input_max/0`). */
export const VENUE_SEARCH_MAX = 120;

/** Shown when the lookup itself could not be reached. */
export const LOOKUP_UNAVAILABLE =
	"Google venue search is unavailable right now; enter the destination details manually";
