<script lang="ts">
import type { RemoteFormField } from "$app/server";
import { Input } from "#lib/components/ui/input/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { ExternalLink, MapPin } from "@lucide/svelte";

/**
 * The destination input (ALE-440): optional, manually entered destination
 * details beside a domain's own short venue label.
 *
 * Domain-neutral on purpose — regular Workshop create/edit and the
 * Beginners' Workshop schedule/reschedule forms (ALE-441) compose the same
 * fields without importing either domain's policy. It only
 * renders the shared field vocabulary (`destination_name`,
 * `destination_address`, `directions_url`) through the remote-form field
 * API, so control names, restored values, `aria-invalid` and field issues
 * all stay connected to the submitting form.
 */
type TextField = RemoteFormField<string>;

let {
	fields,
	values,
	disabled = false,
}: {
	fields: {
		destination_name: TextField;
		destination_address: TextField;
		directions_url: TextField;
	};
	/**
	 * The saved destination each control shows until it is edited (ALE-441),
	 * for forms that prefill through `.as(type, value)` rather than
	 * `fields.set(...)`.
	 */
	values?: {
		destination_name: string;
		destination_address: string;
		directions_url: string;
	};
	disabled?: boolean;
} = $props();
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

	<Field.Field>
		{@const linkField = fields.directions_url.as(
			"text",
			values?.directions_url,
		)}
		<Field.Label for={linkField.name}>Google Maps directions link</Field.Label>
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
</div>
