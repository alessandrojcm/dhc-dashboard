<script lang="ts">
import PublicShell from "$lib/components/layout/PublicShell.svelte";
const { children } = $props();
</script>

<svelte:head>
	<title>Dublin Hema Club - Login</title>
</svelte:head>

<PublicShell eyebrow="Members of Dublin HEMA">{@render children()}</PublicShell>
