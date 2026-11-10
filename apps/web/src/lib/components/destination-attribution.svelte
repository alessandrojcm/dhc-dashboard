<script lang="ts">
import type { DestinationCredit } from "#lib/destinations.js";

/**
 * Google Maps attribution for a destination selected from Google venue
 * search (ALE-442): the "Google Maps" text mark plus any third-party credits
 * Google returned with the place, kept together beside the name and address
 * they credit. Render it only for Google-derived data
 * (`destinationAttribution`); a manual destination is never attributed.
 *
 * Credit links open without a referrer, so a credential-bearing page (the
 * Intake page) never discloses its URL.
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
