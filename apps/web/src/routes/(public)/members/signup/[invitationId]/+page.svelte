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

const { data } = $props();

const view = $derived.by(() => {
	if (data.state === "awaiting_oauth") {
		return {
			step: 2 as const,
			title: "Connect Discord",
			description: "Link the Discord account you use for club communication.",
		};
	}
	if (data.state === "discordVerified") {
		return {
			step: 2 as const,
			title: "Discord verified",
			description: "Check the account below before moving on to payment.",
		};
	}
	if (data.state === "discordCollision") {
		return {
			step: 2 as const,
			title: "This Discord account cannot be used",
			description: "Your membership and payment have not been created.",
		};
	}
	if (data.state === "discordUnavailable") {
		return {
			step: 2 as const,
			title: "Discord is temporarily unavailable",
			description: "Nothing has been charged. You can safely try again.",
		};
	}
	if (data.state === "paymentReady") {
		return {
			step: 3 as const,
			title: "Finish your membership",
			description: "Add an emergency contact and choose your membership plan.",
		};
	}
	if (data.state === "paymentNeedsAction") {
		return {
			step: 3 as const,
			title: "Payment needs attention",
			description:
				"Your progress is safe and your Discord account stays linked.",
		};
	}
	if (data.state === "paymentTerminal") {
		return {
			step: 3 as const,
			title: "Payment could not be completed",
			description: "Your verified invitation is still saved.",
		};
	}
	if (data.state === "paymentPending") {
		return {
			step: 3 as const,
			title: "Payment in progress",
			description: "We are finishing your membership setup.",
		};
	}
	return {
		step: 1 as const,
		title: "Verify Your Invitation",
		description:
			"Confirm the email address and date of birth on your invitation.",
	};
});

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
