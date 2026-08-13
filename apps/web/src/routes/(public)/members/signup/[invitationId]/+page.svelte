<script lang="ts">
import ConfirmInvitation from "./confirm-invitation.svelte";
import AwaitingDiscord from "./awaiting-discord.svelte";

const { data } = $props();
</script>

{#if data.state === "awaitingDiscord"}
	<AwaitingDiscord />
{:else}
	<ConfirmInvitation />
{/if}
