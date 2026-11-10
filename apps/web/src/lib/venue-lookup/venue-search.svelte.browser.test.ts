import { describe, expect, it, vi } from "vitest";
import type {
	LookupResult,
	VenueLookup,
	VenueSelection,
	VenueSuggestion,
} from "#lib/venue-lookup/venue-lookup.js";
import { VenueSearch } from "#lib/venue-lookup/venue-search.svelte.js";

function deferred<T>() {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((r) => (resolve = r));
	return { promise, resolve };
}

const hall: VenueSelection = {
	provider: "google",
	placeId: "place_hall",
	name: "Synthetic Fencing Hall",
	address: "1 Example Street, Dublin 8",
	attributions: [],
};

const suggestions = (...ids: string[]): VenueSuggestion[] =>
	ids.map((id) => ({ placeId: id, text: `Text ${id}` }));

function setup(lookup: Partial<VenueLookup>) {
	const onSelect = vi.fn();
	let tokens = 0;
	const search = new VenueSearch({
		lookup: {
			suggest: lookup.suggest ?? vi.fn(),
			resolve: lookup.resolve ?? vi.fn(),
		},
		onSelect,
		debounceMs: 0,
		newSessionToken: () => `token-${++tokens}`,
	});
	return { search, onSelect };
}

describe("VenueSearch", () => {
	it("shows suggestions for the latest search only, whatever order answers arrive in", async () => {
		const first = deferred<LookupResult<VenueSuggestion[]>>();
		const second = deferred<LookupResult<VenueSuggestion[]>>();
		const suggest = vi
			.fn()
			.mockReturnValueOnce(first.promise)
			.mockReturnValueOnce(second.promise);
		const { search } = setup({ suggest });

		search.input("hal");
		await vi.waitFor(() => expect(suggest).toHaveBeenCalledTimes(1));
		search.input("hall");
		await vi.waitFor(() => expect(suggest).toHaveBeenCalledTimes(2));

		second.resolve({ ok: true, data: suggestions("latest") });
		await vi.waitFor(() => expect(search.status).toBe("ready"));
		first.resolve({ ok: true, data: suggestions("stale") });
		await Promise.resolve();

		expect(search.suggestions.map((s) => s.placeId)).toEqual(["latest"]);
		// Both searches belong to one interaction, so they share its session.
		expect(suggest.mock.calls.map((call) => call[1])).toEqual([
			"token-1",
			"token-1",
		]);
	});

	it("never selects automatically and resolves exactly the chosen suggestion", async () => {
		const suggest = vi
			.fn()
			.mockResolvedValue({ ok: true, data: suggestions("a", "b") });
		const resolve = vi.fn().mockResolvedValue({ ok: true, data: hall });
		const { search, onSelect } = setup({ suggest, resolve });

		search.input("hall");
		await vi.waitFor(() => expect(search.status).toBe("ready"));
		expect(onSelect).not.toHaveBeenCalled();
		expect(search.activeIndex).toBe(-1);

		search.move(1);
		search.move(1);
		search.move(1);
		expect(search.activeIndex).toBe(0);

		await search.choose(1);
		expect(resolve).toHaveBeenCalledWith("b", "token-1");
		expect(onSelect).toHaveBeenCalledWith(hall);
		expect(search.suggestions).toEqual([]);
		expect(search.query).toBe("");

		// The selection ended the session: a replacement search starts a new one.
		search.input("annex");
		await vi.waitFor(() => expect(suggest).toHaveBeenCalledTimes(2));
		expect(suggest).toHaveBeenLastCalledWith("annex", "token-2");
	});

	it("a search answered after a choice cannot replace the chosen destination", async () => {
		const late = deferred<LookupResult<VenueSuggestion[]>>();
		const suggest = vi
			.fn()
			.mockResolvedValueOnce({ ok: true, data: suggestions("a") })
			.mockReturnValueOnce(late.promise);
		const resolve = vi.fn().mockResolvedValue({ ok: true, data: hall });
		const { search, onSelect } = setup({ suggest, resolve });

		search.input("hall");
		await vi.waitFor(() => expect(search.status).toBe("ready"));
		search.input("hall b");
		await vi.waitFor(() => expect(suggest).toHaveBeenCalledTimes(2));
		// The list from the first answer is still showing; pick from it.
		search.suggestions = suggestions("a");
		await search.choose(0);
		late.resolve({ ok: true, data: suggestions("late") });
		await Promise.resolve();

		expect(onSelect).toHaveBeenCalledTimes(1);
		expect(search.suggestions).toEqual([]);
		expect(search.status).toBe("idle");
	});

	it("reports no match, failures and dismissal without selecting", async () => {
		const suggest = vi
			.fn()
			.mockResolvedValueOnce({ ok: true, data: [] })
			.mockResolvedValueOnce({
				ok: false,
				error: "Google venue search isn't set up",
			})
			.mockRejectedValueOnce(new Error("network"));
		const { search, onSelect } = setup({ suggest });

		search.input("nowhere");
		await vi.waitFor(() => expect(search.status).toBe("empty"));

		search.input("quota");
		await vi.waitFor(() => expect(search.status).toBe("failed"));
		expect(search.message).toBe("Google venue search isn't set up");

		search.input("offline");
		await vi.waitFor(() => expect(search.message).toMatch(/unavailable/));

		search.dismiss();
		expect(search.suggestions).toEqual([]);
		expect(onSelect).not.toHaveBeenCalled();
	});

	it("keeps the suggestions and explains when the chosen place cannot be resolved", async () => {
		const suggest = vi
			.fn()
			.mockResolvedValue({ ok: true, data: suggestions("gone") });
		const resolve = vi.fn().mockResolvedValue({
			ok: false,
			error: "That place is no longer available",
		});
		const { search, onSelect } = setup({ suggest, resolve });

		search.input("hall");
		await vi.waitFor(() => expect(search.status).toBe("ready"));
		await search.choose(0);

		expect(onSelect).not.toHaveBeenCalled();
		expect(search.status).toBe("failed");
		expect(search.message).toBe("That place is no longer available");
		expect(search.suggestions.map((s) => s.placeId)).toEqual(["gone"]);
	});

	it("does not search blank or over-long text", async () => {
		const suggest = vi.fn();
		const { search } = setup({ suggest });

		search.input("   ");
		search.input("x".repeat(121));
		await new Promise((r) => setTimeout(r, 5));

		expect(suggest).not.toHaveBeenCalled();
		expect(search.message).toMatch(/up to 120/);
	});
});
