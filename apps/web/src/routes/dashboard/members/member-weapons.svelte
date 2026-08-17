<script lang="ts">
import { Badge } from "$lib/components/ui/badge";

type Props = {
	weapons: string[];
	limit?: number;
};

const { weapons, limit = 2 }: Props = $props();

function weaponLabel(weapon: string): string {
	return weapon.replace(/[-_]/g, " ");
}

const visibleWeapons = $derived(weapons.slice(0, limit));
const remainingCount = $derived(
	Math.max(weapons.length - visibleWeapons.length, 0),
);
</script>

{#if weapons.length > 0}
	<div class="flex flex-wrap gap-1.5" aria-label="Preferred weapons">
		{#each visibleWeapons as weapon (weapon)}
			<Badge variant="outline" class="capitalize">{weaponLabel(weapon)}</Badge>
		{/each}
		{#if remainingCount > 0}
			<Badge variant="secondary">+{remainingCount}</Badge>
		{/if}
	</div>
{:else}
	<span class="text-sm text-muted-foreground">Not set</span>
{/if}
