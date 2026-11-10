/**
 * A faithful in-memory `VenueLookup` for form tests (ALE-442): it answers
 * from a synthetic catalogue (never a recorded provider response) and records
 * every call, so a test can assert the session tokens and the deliberate
 * choice without reaching Phoenix or Google. Provide it to a rendered form
 * through `venueLookupContext`.
 */
import type {
	LookupResult,
	VenueLookup,
	VenueSelection,
	VenueSuggestion,
} from "#lib/venue-lookup/venue-lookup.js";
import { VENUE_LOOKUP_CONTEXT } from "#lib/venue-lookup/venue-lookup-context.js";

export class FakeVenueLookup implements VenueLookup {
	readonly suggestCalls: { input: string; sessionToken: string }[] = [];
	readonly resolveCalls: { placeId: string; sessionToken: string }[] = [];
	/** Set to answer every search with this failure instead. */
	suggestFailure: string | undefined;

	constructor(private readonly places: VenueSelection[]) {}

	async suggest(
		input: string,
		sessionToken: string,
	): Promise<LookupResult<VenueSuggestion[]>> {
		this.suggestCalls.push({ input, sessionToken });
		if (this.suggestFailure) return { ok: false, error: this.suggestFailure };
		const query = input.toLowerCase();
		return {
			ok: true,
			data: this.places
				.filter((place) =>
					`${place.name} ${place.address}`.toLowerCase().includes(query),
				)
				.map((place) => ({
					placeId: place.placeId,
					text: [place.name, place.address].filter(Boolean).join(", "),
				})),
		};
	}

	async resolve(
		placeId: string,
		sessionToken: string,
	): Promise<LookupResult<VenueSelection>> {
		this.resolveCalls.push({ placeId, sessionToken });
		const place = this.places.find(
			(candidate) => candidate.placeId === placeId,
		);
		return place
			? { ok: true, data: place }
			: { ok: false, error: "That place is no longer available" };
	}
}

/** The render `context` that makes a form search through `lookup`. */
export function venueLookupContext(lookup: VenueLookup) {
	return new Map<unknown, unknown>([[VENUE_LOOKUP_CONTEXT, lookup]]);
}
