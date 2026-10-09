<script lang="ts">
import WorkshopConsole from "./workshop-console.svelte";

const { data } = $props();
</script>

<WorkshopConsole
	view={data.console}
	genders={data.genders}
	canInvite={data.canInvite}
/>
