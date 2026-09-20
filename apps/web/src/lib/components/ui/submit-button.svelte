<script lang="ts" module>
import type {
	ButtonVariant,
	ButtonSize,
} from "$lib/components/ui/button/button.svelte";
</script>

<script lang="ts">
import { Check, LoaderCircle } from "@lucide/svelte";
import { Button } from "$lib/components/ui/button";
import { cn } from "$lib/utils.js";
import type { Snippet } from "svelte";

type Props = {
	type?: "submit" | "button";
	variant?: ButtonVariant;
	size?: ButtonSize;
	class?: string;
	disabled?: boolean;
	pending?: boolean;
	succeeded?: boolean;
	pendingLabel?: string;
	successLabel?: string;
	children: Snippet;
	onclick?: (event: MouseEvent) => void;
};

let {
	type = "submit",
	variant = "default",
	size = "default",
	class: className,
	disabled = false,
	pending = false,
	succeeded = false,
	pendingLabel,
	successLabel,
	children,
	onclick,
	...restProps
}: Props = $props();
</script>

<Button
	{type}
	{variant}
	{size}
	disabled={disabled || pending}
	class={cn(
		succeeded && "border-green-700 bg-green-700 text-white hover:bg-green-700",
		className,
	)}
	aria-live="polite"
	{onclick}
	{...restProps}
>
	{#if pending}
		<LoaderCircle
			class="size-4 animate-spin motion-reduce:animate-none"
			aria-hidden="true"
		/>
		{#if pendingLabel}{pendingLabel}{:else}{@render children()}{/if}
	{:else if succeeded}
		<Check class="size-4" aria-hidden="true" />
		{successLabel ?? "Saved"}
	{:else}
		{@render children()}
	{/if}
</Button>
