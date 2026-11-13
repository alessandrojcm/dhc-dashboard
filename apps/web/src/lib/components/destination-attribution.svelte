<script lang="ts">
import type { DestinationCredit } from "#lib/venue-lookup/venue-lookup.js";

/**
 * Google Maps attribution for Google content shown while staff edit a
 * destination (ALE-442): the suggestion list and the transient place
 * preview. The "Google Maps" text mark plus any third-party credits Google
 * returned with the place, kept together beside the text they credit.
 * Attendee surfaces never show Google text (only the Place ID is stored), so
 * they never render it; staff-typed text is never attributed to Google.
 *
 * Credit links open without a referrer.
 */
let {
	credits = [],
	class: className = "",
}: { credits?: DestinationCredit[]; class?: string } = $props();
</script>

<p
	class={`flex flex-wrap items-center gap-x-1.5 text-xs leading-5 text-muted-foreground ${className}`}
	data-testid="destination-attribution"
>
	<span>Place details from</span>
	<span translate="no" class="font-medium text-foreground/80">Google Maps</span>
	{#each credits as credit, index (`${credit.provider}-${index}`)}
		<span aria-hidden="true">·</span>
		{#if credit.providerUri}
			<a
				href={credit.providerUri}
				target="_blank"
				rel="noopener noreferrer"
				referrerpolicy="no-referrer"
				class="underline underline-offset-2 hover:text-foreground"
				>{credit.provider}</a
			>
		{:else}
			<span>{credit.provider}</span>
		{/if}
	{/each}
</p>
