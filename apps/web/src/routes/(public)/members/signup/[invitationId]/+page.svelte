<script lang="ts">
import ConfirmInvitation from "./confirm-invitation.svelte";
import AwaitingDiscord from "./awaiting-discord.svelte";
import DiscordVerified from "./discord-verified.svelte";
import DiscordCollision from "./discord-collision.svelte";
import PaymentStatus from "./payment-status.svelte";

const { data } = $props();
</script>

{#if data.state === "awaitingDiscord"}
	<AwaitingDiscord />
{:else if data.state === "discordVerified"}
	<DiscordVerified {data} discord={data.discord} />
{:else if data.state === "discordCollision"}
	<DiscordCollision />
{:else if data.state === "paymentPending"}
	<PaymentStatus {data} />
{:else}
	<ConfirmInvitation />
{/if}
