<script lang="ts">
import type { RemoteFormField } from "$app/server";
import { onDestroy } from "svelte";
import { Button } from "#lib/components/ui/button/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import LoaderCircle from "#lib/components/ui/loader-circle.svelte";
import DestinationAttribution from "#lib/components/destination-attribution.svelte";
import type { VenueSelection } from "#lib/venue-lookup/venue-lookup.js";
import { currentVenueLookup } from "#lib/venue-lookup/venue-lookup-context.js";
import { VenueSearch } from "#lib/venue-lookup/venue-search.svelte.js";
import { MapPin, X } from "@lucide/svelte";

/**
 * The destination input (ALE-440, ALE-442): one optional autocomplete field
 * beside a domain's own short venue label.
 *
 * Domain-neutral on purpose — regular Workshop create/edit and the
 * Beginners' Workshop schedule/reschedule forms (ALE-441) compose it without
 * importing either domain's policy. It submits two hidden controls of the
 * shared field vocabulary through the remote-form field API:
 *
 *   - `destination_text`: what staff typed, exactly as written, when they did
 *     not choose a suggestion (including when Google is not set up, over
 *     quota, unavailable or has no match);
 *   - `destination_place_id`: the Place ID of a suggestion staff deliberately
 *     chose. The text is then empty: a destination is a place or text, never
 *     both.
 *
 * Search goes through the one venue lookup boundary
 * (`venue-lookup.remote.ts`, or a `VenueLookup` provided through
 * `venue-lookup-context.ts`). Choosing never submits the form. The chosen
 * suggestion's text shows in the input, with Google Maps attribution, for the
 * current editing session only: it is never submitted or stored, and a saved
 * place reopens without Google text (none is fetched again). Typing again
 * discards the selection and starts a new search; the clear button empties
 * the input and any selection.
 */
type TextField = RemoteFormField<string>;
type DestinationKey = "destination_text" | "destination_place_id";

let {
	fields,
	values,
	disabled = false,
}: {
	fields: Record<DestinationKey, TextField>;
	/**
	 * The saved destination the input shows until it is edited (ALE-441), for
	 * forms that prefill through `.as(type, value)` rather than
	 * `fields.set(...)`.
	 */
	values?: Partial<Record<DestinationKey, string>>;
	disabled?: boolean;
} = $props();

const current = (key: DestinationKey) =>
	String(fields[key].value() ?? values?.[key] ?? "");

/** Google's preview of the place chosen in this session; never submitted. */
let preview = $state<VenueSelection | undefined>(undefined);
let inputRef = $state<HTMLInputElement | null>(null);

const search = new VenueSearch({
	lookup: currentVenueLookup(),
	onSelect: applySelection,
});
// The saved manual text is what the input shows first; it is not a search.
search.query = current("destination_text");
onDestroy(() => search.destroy());

const uid = $props.id();
const inputId = `${uid}-destination`;
const listboxId = `${uid}-destination-suggestions`;
const statusId = `${uid}-destination-status`;
const optionId = (index: number) => `${uid}-destination-option-${index}`;

const placeId = $derived(current("destination_place_id").trim());
const isSelected = $derived(placeId !== "");
// The preview belongs to the selected place only: a restored or replaced ID
// never shows another place's Google text.
const shownPreview = $derived(
	preview && preview.placeId === placeId ? preview : undefined,
);
const submittedText = $derived(isSelected ? "" : search.query);
const issues = $derived([
	...(fields.destination_text.issues() ?? []),
	...(fields.destination_place_id.issues() ?? []),
]);

function applySelection(selection: VenueSelection) {
	preview = selection;
	fields.destination_text.set("");
	fields.destination_place_id.set(selection.placeId);
}

function onInput(text: string) {
	// Typing again discards a selection: it is a new search or manual text.
	if (isSelected) {
		preview = undefined;
		fields.destination_place_id.set("");
	}
	fields.destination_text.set(text);
	search.input(text);
}

function clear() {
	preview = undefined;
	search.clear();
	fields.destination_text.set("");
	fields.destination_place_id.set("");
	inputRef?.focus();
}

function onKeydown(event: KeyboardEvent) {
	switch (event.key) {
		case "ArrowDown":
		case "ArrowUp":
			if (!search.open) return;
			event.preventDefault();
			search.move(event.key === "ArrowDown" ? 1 : -1);
			return;
		case "Enter":
			// The destination input never submits the surrounding form.
			event.preventDefault();
			if (search.open && search.activeIndex >= 0)
				void search.choose(search.activeIndex);
			return;
		case "Escape":
			if (!search.open) return;
			event.preventDefault();
			event.stopPropagation();
			search.dismiss();
	}
}

const statusText = $derived.by(() => {
	switch (search.status) {
		case "searching":
			return "Searching Google Maps…";
		case "resolving":
			return "Getting the place details…";
		case "empty":
			return "No places found. What you type is saved as written.";
		case "ready":
			return `${search.suggestions.length} ${search.suggestions.length === 1 ? "place" : "places"} found. Use the arrow keys to review them and Enter to choose one.`;
		case "failed":
			return search.message;
	}
	if (isSelected)
		return "Google Maps place selected. Attendees get directions to it. Type to replace it.";
	return "Optional. Choose a suggestion to link directions to that place, or type the destination and it is saved as written.";
});
</script>

<Field.Field>
	<Field.Label for={inputId}>Destination</Field.Label>
	<div class="relative">
		<span
			class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground"
		>
			{#if search.status === "searching" || search.status === "resolving"}
				<LoaderCircle class="size-4" />
			{:else}
				<MapPin aria-hidden="true" class="size-4" />
			{/if}
		</span>
		<Input
			bind:ref={inputRef}
			id={inputId}
			type="text"
			role="combobox"
			autocomplete="off"
			aria-autocomplete="list"
			aria-expanded={search.open}
			aria-controls={listboxId}
			aria-describedby={statusId}
			aria-invalid={issues.length > 0 ? true : undefined}
			aria-activedescendant={search.activeIndex >= 0
				? optionId(search.activeIndex)
				: undefined}
			placeholder={isSelected && !shownPreview
				? "Google Maps place selected"
				: "Venue name or address"}
			maxlength={500}
			class="h-11 pl-9 pr-11"
			value={search.query}
			oninput={(event) => onInput(event.currentTarget.value)}
			onkeydown={onKeydown}
			onblur={() => search.dismiss()}
			{disabled}
		/>
		{#if search.query !== "" || isSelected}
			<Button
				type="button"
				variant="ghost"
				size="icon"
				class="absolute right-0 top-1/2 -translate-y-1/2 text-muted-foreground"
				aria-label="Clear destination"
				onclick={clear}
				{disabled}
			>
				<X aria-hidden="true" />
			</Button>
		{/if}
	</div>

	<div
		hidden={!search.open}
		class="overflow-hidden rounded-lg border border-border bg-popover text-popover-foreground shadow-md"
	>
		<ul
			id={listboxId}
			role="listbox"
			aria-label="Google Maps suggestions"
			class="max-h-64 overflow-y-auto py-1"
		>
			{#each search.suggestions as suggestion, index (suggestion.placeId)}
				<!-- Keyboard choice stays on the combobox input (ARIA combobox pattern). -->
				<!-- svelte-ignore a11y_click_events_have_key_events -->
				<li
					id={optionId(index)}
					role="option"
					aria-selected={index === search.activeIndex}
					class="flex min-h-11 cursor-pointer items-center gap-2 px-3 py-2 text-sm leading-5 aria-selected:bg-accent aria-selected:text-accent-foreground"
					onmousedown={(event) => event.preventDefault()}
					onclick={() => void search.choose(index)}
				>
					<MapPin
						aria-hidden="true"
						class="size-4 shrink-0 text-muted-foreground"
					/>
					<span>{suggestion.text}</span>
				</li>
			{/each}
		</ul>
		{#if search.open}
			<DestinationAttribution class="border-t border-border/70 px-3 py-1.5" />
		{/if}
	</div>

	{#if shownPreview}
		<!-- The input shows Google's text for this editing session only. -->
		<DestinationAttribution credits={shownPreview.attributions} />
	{/if}

	<p
		id={statusId}
		role="status"
		aria-live="polite"
		class="text-sm leading-5 text-muted-foreground"
	>
		{statusText}
	</p>

	{#each issues as issue, index (`${issue.message}-${index}`)}
		<Field.Error>{issue.message}</Field.Error>
	{/each}

	<input {...fields.destination_text.as("hidden", submittedText)} />
	<input {...fields.destination_place_id.as("hidden", placeId)} />
</Field.Field>
