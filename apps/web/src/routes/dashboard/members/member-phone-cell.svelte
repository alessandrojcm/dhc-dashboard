<script lang="ts">
type Props = {
	phone: string | null;
};

const { phone }: Props = $props();
</script>

{#if phone}
	<a
		href={`tel:${phone}`}
		class="text-sm font-medium text-foreground underline-offset-4 transition-colors duration-200 hover:text-primary hover:underline focus-visible:rounded-sm focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
	>
		{phone}
	</a>
{:else}
	<span class="text-sm text-muted-foreground">Not provided</span>
{/if}
