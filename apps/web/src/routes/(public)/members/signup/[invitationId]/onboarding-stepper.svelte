<script lang="ts">
import {
	CheckIcon,
	CreditCardIcon,
	MessageCircleIcon,
	UserRoundCheckIcon,
} from "@lucide/svelte";

let { currentStep }: { currentStep: 1 | 2 | 3 } = $props();

const steps = [
	{ label: "Verify invitation", icon: UserRoundCheckIcon },
	{ label: "Connect Discord", icon: MessageCircleIcon },
	{ label: "Membership & payment", icon: CreditCardIcon },
] as const;
</script>

<nav aria-label="Membership setup progress" class="onboarding-progress">
	<ol class="grid grid-cols-3 gap-2">
		{#each steps as step, index (step.label)}
			{@const stepNumber = index + 1}
			{@const complete = stepNumber < currentStep}
			{@const active = stepNumber === currentStep}
			{@const Icon = step.icon}
			<li
				class="progress-step relative flex min-w-0 flex-col items-center gap-2 text-center"
				class:complete
				class:active
				aria-current={active ? "step" : undefined}
			>
				<span
					class="step-marker relative z-10 grid size-10 shrink-0 place-items-center rounded-full border-2 bg-card transition-[background-color,border-color,color,transform] duration-300"
				>
					{#if complete}
						<CheckIcon class="size-4" strokeWidth={3} aria-hidden="true" />
					{:else}
						<Icon class="size-4" strokeWidth={2.25} aria-hidden="true" />
					{/if}
				</span>
				<span class="min-w-0">
					<span
						class="hidden text-[0.68rem] font-bold uppercase tracking-[0.14em] text-muted-foreground sm:block"
					>
						Step {stepNumber}
					</span>
					<span
						class="block text-xs font-semibold leading-tight text-muted-foreground sm:text-sm"
					>
						{step.label}
					</span>
				</span>
			</li>
		{/each}
	</ol>
</nav>

<style>
.progress-step:not(:last-child)::after {
	content: "";
	position: absolute;
	top: 1.25rem;
	left: calc(50% + 1.5rem);
	right: calc(-50% + 1.5rem);
	height: 2px;
	background: hsl(var(--border));
}

.step-marker {
	color: hsl(var(--muted-foreground));
	border-color: hsl(var(--border));
}

.progress-step.complete .step-marker {
	color: hsl(var(--primary-foreground));
	border-color: hsl(var(--primary));
	background: hsl(var(--primary));
}

.progress-step.active .step-marker {
	color: hsl(var(--primary));
	border-color: hsl(var(--secondary));
	background: hsl(var(--secondary) / 0.16);
	transform: translateY(-2px);
	box-shadow: 0 0 0 4px hsl(var(--secondary) / 0.12);
}

.progress-step.active span:last-child span:last-child {
	color: hsl(var(--foreground));
}

@media (prefers-reduced-motion: reduce) {
	.step-marker {
		transition: none;
	}
}
</style>
