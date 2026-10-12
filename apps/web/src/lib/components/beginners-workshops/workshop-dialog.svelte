<script lang="ts">
import type { Snippet } from "svelte";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as AlertDialog from "#lib/components/ui/alert-dialog/index.js";

let {
	children,
	wide = false,
	alert = false,
}: { children: Snippet; wide?: boolean; alert?: boolean } = $props();
let alertRef = $state<HTMLDivElement | null>(null);
</script>

{#if alert}
	<AlertDialog.Content
		bind:ref={alertRef}
		class="workshop-dialog sm:max-w-xl"
		onOpenAutoFocus={(event) => {
			const cancel = alertRef?.querySelector<HTMLButtonElement>(
				"[data-alert-dialog-cancel]",
			);
			if (cancel) {
				event.preventDefault();
				cancel.focus();
			}
		}}
	>
		{@render children()}
	</AlertDialog.Content>
{:else}
	<Dialog.Content
		class={`workshop-dialog ${wide ? "sm:max-w-3xl" : "sm:max-w-xl"}`}
	>
		{@render children()}
	</Dialog.Content>
{/if}

<style>
:global(.workshop-dialog) {
	max-height: calc(100dvh - 2rem);
	gap: 0;
	padding: 0;
	overflow: hidden;
	grid-template-rows: auto minmax(0, 1fr);
	background: hsl(var(--background));
	color: hsl(var(--foreground));
	border-radius: 1rem;
}

:global(
	.workshop-dialog
		> :is([data-slot="dialog-header"], [data-slot="alert-dialog-header"])
) {
	position: sticky;
	top: 0;
	z-index: 2;
	background: hsl(var(--background));
	padding: 1.5rem 3.5rem 1.25rem 1.5rem;
	border-bottom: 1px solid hsl(var(--border));
	text-align: left;
}

:global(
	.workshop-dialog
		:is([data-slot="dialog-title"], [data-slot="alert-dialog-title"])
) {
	font-size: 1.125rem;
	line-height: 1.3;
}

:global(.workshop-dialog > button) {
	z-index: 3;
}

:global(
	.workshop-dialog
		:is(
			[data-slot="dialog-description"],
			[data-slot="alert-dialog-description"]
		)
) {
	color: hsl(var(--muted-foreground));
	font-size: 0.875rem;
	line-height: 1.6;
}

:global(.workshop-dialog > form),
:global(.workshop-dialog > .workshop-dialog-body) {
	min-height: 0;
	overflow-y: auto;
	overscroll-behavior: contain;
	padding: 1.5rem 1.5rem 0;
	scroll-padding-block: 1rem 6rem;
}

:global(
	.workshop-dialog
		:is([data-slot="dialog-footer"], [data-slot="alert-dialog-footer"])
) {
	position: sticky;
	bottom: 0;
	z-index: 1;
	margin: 0 -1.5rem;
	padding: 1rem 1.5rem;
	border-top: 1px solid hsl(var(--border));
	background: hsl(var(--background));
	gap: 0.75rem;
}
:global(.workshop-dialog > [data-slot="alert-dialog-footer"]) {
	margin: 0;
}
:global(.workshop-dialog label:has([role="radio"])) {
	display: flex;
	background: hsl(var(--field-background));
	align-items: flex-start;
	padding: 1rem;
	gap: 0.75rem;
}

:global(.workshop-dialog input:not([type="hidden"])),
:global(.workshop-dialog select),
:global(.workshop-dialog textarea) {
	min-height: 2.75rem;
}

:global(.workshop-dialog textarea) {
	min-height: 6rem;
}

:global(.workshop-dialog [data-slot="button"]) {
	min-height: 2.75rem;
}

:global(.workshop-dialog .workshop-dialog-section) {
	border: 1px solid hsl(var(--border));
	border-radius: 0.75rem;
	padding: 1rem;
	background: hsl(var(--background));
}

:global(.workshop-dialog .workshop-dialog-notice) {
	padding: 1rem;
	border: 1px solid hsl(var(--border));
	border-left: 4px solid hsl(var(--primary));
	border-radius: 0.5rem;
	background: hsl(var(--muted));
	color: hsl(var(--foreground));
	font-size: 0.875rem;
	line-height: 1.6;
}

:global(.workshop-dialog .workshop-dialog-danger) {
	border-left-color: hsl(var(--destructive));
}

:global(.workshop-dialog [role="alert"]:not([data-slot="alert"])),
:global(.workshop-dialog [data-slot="field-error"]) {
	color: hsl(var(--foreground));
	border-left: 3px solid hsl(var(--destructive));
	padding-left: 0.75rem;
	font-size: 0.875rem;
	line-height: 1.5;
}

:global(.workshop-dialog > button:last-child) {
	width: 2.75rem;
	height: 2.75rem;
	top: 0.75rem;
	right: 0.75rem;
	opacity: 1;
}

@media (max-width: 639px) {
	:global(.workshop-dialog) {
		inset: auto 0 0;
		width: 100%;
		max-width: none;
		max-height: calc(100dvh - 1rem);
		translate: none;
		border-radius: 1rem 1rem 0 0;
		border-bottom: 0;
	}
	:global(.workshop-dialog[data-state="open"]) {
		animation: workshop-sheet-in 250ms ease-out;
	}
	:global(.workshop-dialog[data-state="closed"]) {
		animation: workshop-sheet-out 200ms ease-in;
	}
	:global(.workshop-dialog [data-slot="dialog-title"]),
	:global(.workshop-dialog [data-slot="alert-dialog-title"]) {
		font-size: 1.125rem;
	}
	:global(
		.workshop-dialog
			> :is([data-slot="dialog-header"], [data-slot="alert-dialog-header"])
	) {
		padding-left: 1rem;
	}
	:global(.workshop-dialog > form),
	:global(.workshop-dialog > .workshop-dialog-body) {
		padding: 1rem 1rem 0;
	}
	:global(
		.workshop-dialog
			:is([data-slot="dialog-footer"], [data-slot="alert-dialog-footer"])
	) {
		margin-inline: -1rem;
		padding: 1rem 1rem max(1rem, env(safe-area-inset-bottom));
	}
	:global(.workshop-dialog > [data-slot="alert-dialog-footer"]) {
		margin: 0;
	}
}

@keyframes -global-workshop-sheet-in {
	from {
		transform: translateY(100%);
	}
	to {
		transform: translateY(0);
	}
}

@keyframes -global-workshop-sheet-out {
	from {
		transform: translateY(0);
	}
	to {
		transform: translateY(100%);
	}
}

@media (prefers-reduced-motion: reduce) {
	:global(.workshop-dialog[data-state]) {
		animation: none;
		transition: none;
	}
}
</style>
