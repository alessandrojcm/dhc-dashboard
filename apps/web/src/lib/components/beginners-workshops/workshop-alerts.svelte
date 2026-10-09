<!--
	ALE-379: a Beginners' Workshop's alerts as Phoenix judges them (today only
	"Unstaffed"), shared by the Workshops list and the workshop pages.
-->
<script lang="ts">
import type { BeginnersWorkshopAlert } from "@dhc/api-client";
import { AlertTriangle } from "@lucide/svelte";
import { alertLabel } from "#lib/beginners-workshops/presentation.js";
import { Badge } from "#lib/components/ui/badge/index.js";

let { alerts }: { alerts: BeginnersWorkshopAlert[] } = $props();
</script>

{#each alerts as alert (alert)}
	<Badge variant="outline" class="border-amber-500 bg-amber-50 text-amber-900">
		<AlertTriangle />
		{alertLabel(alert)}
	</Badge>
{/each}
