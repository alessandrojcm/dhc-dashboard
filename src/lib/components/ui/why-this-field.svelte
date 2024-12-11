<script lang="ts" module>
    import * as Tooltip from '$lib/components/ui/tooltip';
    import { HelpCircle } from 'lucide-svelte';

    export { whyThisField };
</script>

{#snippet whyThisField(message: string)}
	<Tooltip.Provider>
		<Tooltip.Root>
			<Tooltip.Trigger>
				<HelpCircle class="h-4 w-4 text-muted-foreground" />
			</Tooltip.Trigger>
			<Tooltip.Content>
				{message}
			</Tooltip.Content>
		</Tooltip.Root>
	</Tooltip.Provider>
{/snippet}
