/**
 * The venue search interaction behind the destination input (ALE-442).
 *
 * One instance per mounted input. It owns the Google session lifecycle and
 * the ordering guarantees the ALE-439 contract asks for:
 *
 *   - a search interaction starts a fresh random session token and ends it on
 *     a resolved selection or on dismissal; a replacement search starts anew;
 *   - typing is debounced, and every answer is tagged with the request that
 *     asked, so an out-of-order or superseded answer never replaces the
 *     latest search, and nothing arrives after a choice or a dismissal;
 *   - nothing is chosen automatically: `choose(index)` is the only path to a
 *     selection, and it resolves exactly the suggestion the person picked.
 *
 * It holds suggestions only for the current search and drops them on choice,
 * dismissal or `destroy()`. It never touches the form: the input applies a
 * selection through `onSelect`.
 */
import type {
	VenueLookup,
	VenueSelection,
	VenueSuggestion,
} from "#lib/venue-lookup/venue-lookup.js";
import {
	LOOKUP_UNAVAILABLE,
	VENUE_SEARCH_MAX,
} from "#lib/venue-lookup/venue-lookup.js";

export type VenueSearchStatus =
	| "idle"
	| "searching"
	| "ready"
	| "empty"
	| "resolving"
	| "failed";

export interface VenueSearchOptions {
	lookup: VenueLookup;
	onSelect: (selection: VenueSelection) => void;
	/** Debounce before a search is sent (ms). */
	debounceMs?: number;
	/** A fresh UUID v4 per search interaction. */
	newSessionToken?: () => string;
}

export class VenueSearch {
	query = $state("");
	suggestions = $state<VenueSuggestion[]>([]);
	status = $state<VenueSearchStatus>("idle");
	message = $state<string | undefined>(undefined);
	activeIndex = $state(-1);

	/** Whether the suggestion list is showing. */
	readonly open = $derived(this.suggestions.length > 0);

	#lookup: VenueLookup;
	#onSelect: (selection: VenueSelection) => void;
	#debounceMs: number;
	#newSessionToken: () => string;
	#sessionToken: string | undefined;
	#request = 0;
	#timer: ReturnType<typeof setTimeout> | undefined;

	constructor(options: VenueSearchOptions) {
		this.#lookup = options.lookup;
		this.#onSelect = options.onSelect;
		this.#debounceMs = options.debounceMs ?? 250;
		this.#newSessionToken =
			options.newSessionToken ?? (() => crypto.randomUUID());
	}

	/** The person typed: search (debounced) for the trimmed text. */
	input(text: string) {
		this.query = text;
		this.#cancelPending();
		const trimmed = text.trim();

		if (!trimmed) {
			this.#reset("idle");
			return;
		}

		if (trimmed.length > VENUE_SEARCH_MAX) {
			this.#reset("failed");
			this.message = `Search with up to ${VENUE_SEARCH_MAX} characters.`;
			return;
		}

		this.#sessionToken ??= this.#newSessionToken();
		this.status = "searching";
		this.message = undefined;
		const request = ++this.#request;
		this.#timer = setTimeout(
			() => void this.#search(trimmed, request),
			this.#debounceMs,
		);
	}

	/** Moves the highlighted suggestion (wrapping), for arrow keys. */
	move(delta: 1 | -1) {
		const count = this.suggestions.length;
		if (count === 0) return;
		this.activeIndex =
			this.activeIndex < 0
				? delta > 0
					? 0
					: count - 1
				: (this.activeIndex + delta + count) % count;
	}

	/** Deliberately picks one suggestion and resolves it into a preview. */
	async choose(index: number) {
		const suggestion = this.suggestions[index];
		const sessionToken = this.#sessionToken;
		if (!suggestion || !sessionToken || this.status === "resolving") return;

		this.#cancelPending();
		const request = ++this.#request;
		this.activeIndex = index;
		this.status = "resolving";
		this.message = undefined;

		const result = await this.#safely(() =>
			this.#lookup.resolve(suggestion.placeId, sessionToken),
		);
		if (request !== this.#request) return;

		if (result.ok) {
			// The selection ends the session; the next search starts a new one.
			this.#sessionToken = undefined;
			this.query = "";
			this.#reset("idle");
			this.#onSelect(result.data);
		} else {
			this.status = "failed";
			this.message = result.error;
		}
	}

	/** Closes the suggestions and abandons the session (Escape, blur). */
	dismiss() {
		this.#cancelPending();
		this.#request++;
		this.#sessionToken = undefined;
		this.#reset(this.status === "failed" ? "failed" : "idle");
	}

	/** Drops everything on unmount. */
	destroy() {
		this.dismiss();
		this.query = "";
		this.message = undefined;
	}

	async #search(input: string, request: number) {
		const sessionToken = this.#sessionToken;
		if (!sessionToken) return;

		const result = await this.#safely(() =>
			this.#lookup.suggest(input, sessionToken),
		);
		// A newer search, a choice or a dismissal superseded this answer.
		if (request !== this.#request) return;

		if (!result.ok) {
			this.suggestions = [];
			this.activeIndex = -1;
			this.status = "failed";
			this.message = result.error;
			return;
		}

		this.suggestions = result.data;
		this.activeIndex = -1;
		this.status = result.data.length > 0 ? "ready" : "empty";
	}

	async #safely<Data>(
		call: () => Promise<
			{ ok: true; data: Data } | { ok: false; error: string }
		>,
	) {
		try {
			return await call();
		} catch {
			return { ok: false as const, error: LOOKUP_UNAVAILABLE };
		}
	}

	#cancelPending() {
		if (this.#timer !== undefined) clearTimeout(this.#timer);
		this.#timer = undefined;
	}

	#reset(status: VenueSearchStatus) {
		this.suggestions = [];
		this.activeIndex = -1;
		this.status = status;
		if (status === "idle") this.message = undefined;
	}
}
