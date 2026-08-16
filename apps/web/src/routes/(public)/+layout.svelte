<script lang="ts">
import PublicShell from "$lib/components/layout/PublicShell.svelte";
const { children } = $props();
</script>

<svelte:head>
	<title>Dublin Hema Club - Join</title>
</svelte:head>

<PublicShell eyebrow="Join Dublin HEMA Club">{@render children()}</PublicShell>
