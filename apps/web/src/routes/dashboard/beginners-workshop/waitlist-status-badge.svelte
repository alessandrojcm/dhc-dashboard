<!--
	The Waitlist's Status: the standing as a badge, with "Workshop credit" on a
	line below it when the person holds a Carried Fee (ALE-388). Both are
	getters, re-read when the page's Carried Fee statuses arrive, which a
	static table cell would miss. Kept to two short lines so the column stays
	narrow.
-->
<script lang="ts">
import { Badge } from "#lib/components/ui/badge/index.js";

let {
	removed,
	text,
	credit,
}: { removed: boolean; text: () => string; credit: () => boolean } = $props();
</script>

<div class="flex flex-col items-start gap-1">
	<Badge variant={removed ? "outline" : "secondary"} class="whitespace-nowrap"
		><span>{text()}</span></Badge
	>
	{#if credit()}
		<span class="text-xs font-medium text-muted-foreground"
			>Workshop credit</span
		>
	{/if}
</div>
