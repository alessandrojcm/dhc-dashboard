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
import { ExternalLink, MapPin, Search } from "@lucide/svelte";

/**
 * The destination input (ALE-440, ALE-442): optional destination details
 * beside a domain's own short venue label, typed by staff, plus an optional
 * place chosen with Google Maps venue search for directions.
 *
 * Domain-neutral on purpose — regular Workshop create/edit and the
 * Beginners' Workshop schedule/reschedule forms (ALE-441) compose the same
 * fields without importing either domain's policy. It renders the shared
 * field vocabulary (`destination_name`, `destination_address`,
 * `directions_url`, and the selected place's hidden `destination_place_id`)
 * through the remote-form field API, so control names, restored values,
 * `aria-invalid` and field issues all stay connected to the submitting form.
 *
 * Search goes through the one venue lookup boundary
 * (`venue-lookup.remote.ts`, or a `VenueLookup` provided through
 * `venue-lookup-context.ts`). A suggestion becomes the selected place only
 * when it is deliberately chosen; choosing never submits the form. Only the
 * Place ID is submitted and saved: Google's name, address and credits are a
 * preview held in this component for the current editing session, shown with
 * Google Maps attribution and discarded on remove, replace or unmount. The
 * name and address controls stay independent staff-typed text — a selection
 * never fills them — and are what attendees and Calendar see. A saved place
 * reopens without Google text (none is stored, and none is fetched again).
 * Manual entry always works, including when Google is not set up, over quota
 * or unavailable.
 */
type TextField = RemoteFormField<string>;
type DestinationKey =
	| "destination_name"
	| "destination_address"
	| "directions_url"
	| "destination_place_id";

let {
	fields,
	values,
	disabled = false,
}: {
	fields: Record<DestinationKey, TextField>;
	/**
	 * The saved destination each control shows until it is edited (ALE-441),
	 * for forms that prefill through `.as(type, value)` rather than
	 * `fields.set(...)`.
	 */
	values?: Partial<Record<DestinationKey, string>>;
	disabled?: boolean;
} = $props();

/** Google's preview of the place chosen in this session; never submitted. */
let preview = $state<VenueSelection | undefined>(undefined);

const search = new VenueSearch({
	lookup: currentVenueLookup(),
	onSelect: applySelection,
});
onDestroy(() => search.destroy());

const uid = $props.id();
const searchId = `${uid}-venue-search`;
const listboxId = `${uid}-venue-suggestions`;
const optionId = (index: number) => `${uid}-venue-option-${index}`;

const current = (key: DestinationKey) =>
	String(fields[key].value() ?? values?.[key] ?? "");

const placeId = $derived(current("destination_place_id").trim());
const isSelected = $derived(placeId !== "");
// The preview belongs to the selected place only: a restored or replaced ID
// never shows another place's Google text.
const shownPreview = $derived(
	preview && preview.placeId === placeId ? preview : undefined,
);

function applySelection(selection: VenueSelection) {
	preview = selection;
	// A selected place's directions link is derived from it.
	fields.directions_url.set("");
	fields.destination_place_id.set(selection.placeId);
}

function removeSelection() {
	preview = undefined;
	fields.destination_place_id.set("");
}

function onSearchKeydown(event: KeyboardEvent) {
	switch (event.key) {
		case "ArrowDown":
		case "ArrowUp":
			if (!search.open) return;
			event.preventDefault();
			search.move(event.key === "ArrowDown" ? 1 : -1);
			return;
		case "Enter":
			// The search box never submits the surrounding form.
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
			return "No places found. Try another name, or enter the details below.";
		case "ready":
			return `${search.suggestions.length} ${search.suggestions.length === 1 ? "place" : "places"} found. Use the arrow keys to review them and Enter to choose one.`;
		case "failed":
			return search.message;
		default:
			return undefined;
	}
});
</script>

<div
	class="grid gap-5 rounded-xl border border-border/70 bg-muted/15 p-4 sm:p-5"
	aria-labelledby="destination-details-heading"
>
	<div class="flex items-start gap-3">
		<span
			class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-background text-primary shadow-xs"
		>
			<MapPin aria-hidden="true" class="size-4" />
		</span>
		<div>
			<h3 id="destination-details-heading" class="text-sm font-semibold">
				Destination details
			</h3>
			<p class="mt-0.5 text-sm leading-5 text-muted-foreground">
				Optional. Help attendees find the venue with a recognizable name and
				address, shown beside the short location label.
			</p>
		</div>
	</div>

	<Field.Field>
		<Field.Label for={searchId}>
			{isSelected ? "Replace with another place" : "Search Google Maps"}
		</Field.Label>
		<div class="relative">
			<span
				class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground"
			>
				{#if search.status === "searching" || search.status === "resolving"}
					<LoaderCircle class="size-4" />
				{:else}
					<Search aria-hidden="true" class="size-4" />
				{/if}
			</span>
			<Input
				id={searchId}
				type="text"
				role="combobox"
				autocomplete="off"
				aria-autocomplete="list"
				aria-expanded={search.open}
				aria-controls={listboxId}
				aria-describedby={`${searchId}-status`}
				aria-activedescendant={search.activeIndex >= 0
					? optionId(search.activeIndex)
					: undefined}
				placeholder="Venue name or address"
				class="h-11 pl-9"
				value={search.query}
				oninput={(event) => search.input(event.currentTarget.value)}
				onkeydown={onSearchKeydown}
				onblur={() => search.dismiss()}
				{disabled}
			/>
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
			<DestinationAttribution class="border-t border-border/70 px-3 py-1.5" />
		</div>

		<p
			id={`${searchId}-status`}
			role="status"
			aria-live="polite"
			class="text-sm leading-5 text-muted-foreground"
		>
			{statusText ??
				"Choose a suggestion to link directions to that place; nothing is saved until you save the form."}
		</p>
	</Field.Field>

	{#if isSelected}
		<input {...fields.destination_place_id.as("hidden", placeId)} />
		<input {...fields.directions_url.as("hidden", "")} />

		<section
			aria-label="Selected place"
			class="grid gap-3 rounded-lg border border-border bg-background p-4 sm:flex sm:items-start sm:justify-between"
		>
			<div class="grid gap-1">
				{#if shownPreview}
					<!-- Google's text for this editing session only, with attribution. -->
					<p class="text-sm font-semibold">
						{shownPreview.name || shownPreview.address || "Google Maps place"}
					</p>
					{#if shownPreview.name && shownPreview.address}
						<p class="text-sm leading-5 text-muted-foreground">
							{shownPreview.address}
						</p>
					{/if}
					<DestinationAttribution credits={shownPreview.attributions} />
				{:else}
					<p class="text-sm font-semibold">Google Maps place selected</p>
				{/if}
				<p class="text-sm leading-5 text-muted-foreground">
					Attendees get directions to this place. They see the name and address
					you enter below, or the location label when those are empty.
				</p>
				{#each fields.destination_place_id.issues() as issue, index (`${issue.message}-${index}`)}
					<Field.Error>{issue.message}</Field.Error>
				{/each}
			</div>
			<Button
				type="button"
				variant="outline"
				class="h-11 sm:h-9"
				onclick={removeSelection}
				{disabled}
			>
				Remove place
			</Button>
		</section>
	{:else}
		<input {...fields.destination_place_id.as("hidden", "")} />
	{/if}

	<div class="grid grid-cols-1 gap-5 md:grid-cols-2">
		<Field.Field>
			{@const nameField = fields.destination_name.as(
				"text",
				values?.destination_name,
			)}
			<Field.Label for={nameField.name}>Destination name</Field.Label>
			<Input
				{...nameField}
				id={nameField.name}
				placeholder="e.g. National Basketball Arena"
				class="h-11"
				{disabled}
			/>
			{#each fields.destination_name.issues() as issue, index (`${issue.message}-${index}`)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>

		<Field.Field>
			{@const addressField = fields.destination_address.as(
				"text",
				values?.destination_address,
			)}
			<Field.Label for={addressField.name}>Destination address</Field.Label>
			<Input
				{...addressField}
				id={addressField.name}
				placeholder="e.g. Tymon Park, Dublin 6w"
				class="h-11"
				{disabled}
			/>
			{#each fields.destination_address.issues() as issue, index (`${issue.message}-${index}`)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>
	</div>

	{#if !isSelected}
		<Field.Field>
			{@const linkField = fields.directions_url.as(
				"text",
				values?.directions_url,
			)}
			<Field.Label for={linkField.name}>Google Maps directions link</Field.Label
			>
			<div class="relative">
				<span
					class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground"
				>
					<ExternalLink aria-hidden="true" class="size-4" />
				</span>
				<Input
					{...linkField}
					id={linkField.name}
					type="url"
					placeholder="https://maps.app.goo.gl/…"
					class="h-11 pl-9"
					{disabled}
				/>
			</div>
			<p class="text-sm leading-5 text-muted-foreground">
				Optional. A Google Maps link attendees can open for directions; leave it
				empty to send people to the destination name and address.
			</p>
			{#each fields.directions_url.issues() as issue, index (`${issue.message}-${index}`)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>
	{/if}
</div>
