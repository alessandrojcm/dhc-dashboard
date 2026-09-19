<script lang="ts">
import { cubicOut } from "svelte/easing";
import { prefersReducedMotion } from "svelte/motion";
import { fade, fly } from "svelte/transition";
import ConfirmInvitation from "./confirm-invitation.svelte";
import AwaitingDiscord from "./awaiting-discord.svelte";
import DiscordVerified from "./discord-verified.svelte";
import DiscordCollision from "./discord-collision.svelte";
import PaymentForm from "./payment-form.svelte";
import PaymentStatus from "./payment-status.svelte";
import DiscordUnavailable from "./discord-unavailable.svelte";
import OnboardingStepper from "./onboarding-stepper.svelte";
import { presentAcceptanceStep } from "$lib/invitation-acceptance/presentation";

const { data } = $props();

const view = $derived(presentAcceptanceStep(data.state));

function focusStepHeading(event: Event) {
	if (!(event.currentTarget instanceof HTMLElement)) return;
	event.currentTarget
		.querySelector<HTMLHeadingElement>("h1")
		?.focus({ preventScroll: true });
}
</script>

<div>
	<div class="border-b border-border/70 bg-muted/20 px-6 py-5 sm:px-8">
		<OnboardingStepper currentStep={view.step} />
	</div>

	<div class="min-w-0 p-6 sm:p-8 lg:p-10">
		<div class="step-stage">
			{#key data.state}
				<section
					class="step-view"
					aria-labelledby="onboarding-step-heading"
					in:fly={{
						x: prefersReducedMotion.current ? 0 : 28,
						duration: prefersReducedMotion.current ? 0 : 280,
						easing: cubicOut,
					}}
					out:fade={{ duration: prefersReducedMotion.current ? 0 : 140 }}
					onintroend={focusStepHeading}
				>
					<div class="mb-7 border-b border-border/70 pb-6">
						<p
							class="mb-2 text-xs font-bold uppercase tracking-[0.18em] text-primary"
						>
							Step {view.step} of 3
						</p>
						<h1
							id="onboarding-step-heading"
							tabindex="-1"
							class="text-3xl leading-tight outline-none sm:text-4xl"
						>
							{view.title}
						</h1>
						<p
							class="mt-3 max-w-xl text-sm leading-6 text-muted-foreground sm:text-base"
						>
							{view.description}
						</p>
					</div>

					{#if data.state === "awaitingDiscord"}
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
				</section>
			{/key}
		</div>
	</div>
</div>

<style>
.step-stage {
	display: grid;
}

.step-view {
	grid-area: 1 / 1;
}
</style>
