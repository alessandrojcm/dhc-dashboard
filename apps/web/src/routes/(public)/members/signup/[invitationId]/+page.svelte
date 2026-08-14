<script lang="ts">
import ConfirmInvitation from "./confirm-invitation.svelte";
import AwaitingDiscord from "./awaiting-discord.svelte";
import DiscordVerified from "./discord-verified.svelte";
import DiscordCollision from "./discord-collision.svelte";
import PaymentForm from "./payment-form.svelte";
import PaymentStatus from "./payment-status.svelte";
import DiscordUnavailable from "./discord-unavailable.svelte";

const { data } = $props();
</script>

{#if data.state === "awaiting_oauth"}
	<AwaitingDiscord />
{:else if data.state === "discordVerified"}
	<DiscordVerified discord={data.discord} />
{:else if data.state === "discordCollision"}
	<DiscordCollision />
{:else if data.state === "paymentReady"}
	<PaymentForm {data} />
{:else if data.state === "paymentPending" || data.state === "paymentNeedsAction" || data.state === "paymentTerminal"}
	<PaymentStatus {data} />
{:else if data.state === "discordUnavailable"}
	<DiscordUnavailable />
{:else}
	<ConfirmInvitation />
{/if}
