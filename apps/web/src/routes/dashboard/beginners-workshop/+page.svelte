<script lang="ts">
import type { PageProps } from "./$types";
import Analytics from "./workshop-analytics.svelte";
let { data }: PageProps = $props();
</script>

<div class="h-full min-h-0 overflow-y-auto pb-4">
	<Analytics canManageWorkshops={data.canManageWorkshops} />
</div>
