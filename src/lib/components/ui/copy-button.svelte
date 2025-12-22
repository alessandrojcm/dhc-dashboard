<script lang="ts">
import { Button } from '$lib/components/ui/button';
import * as Tooltip from '$lib/components/ui/tooltip';
import { Check, Copy, X } from 'lucide-svelte';
import { fade } from 'svelte/transition';

const {
	text,
	label = "Copy",
	size = "icon",
	variant = "ghost",
} = $props<{
	text: string;
	label?: string;
	size?: "sm" | "default" | "lg" | "icon" | null;
	variant?:
		| "ghost"
		| "outline"
		| "link"
		| "default"
		| "destructive"
		| "secondary"
		| null;
}>();

let _isCopied: "copied" | "not-copied" | "error" = $state("not-copied");

async function _copyToClipboard() {
	try {
		await navigator.clipboard.writeText(text);
		_isCopied = "copied";

		// Reset the copied state after 2 seconds
		setTimeout(() => {
			_isCopied = "not-copied";
		}, 2000);

		return true;
	} catch (error) {
		console.error("Failed to copy text:", error);
		_isCopied = "error";
		return false;
	}
}
</script>

<Tooltip.Tooltip>
	<Tooltip.Trigger>
		<Button
			type="button"
			{size}
			{variant}
			onclick={_copyToClipboard}
			class="relative"
			aria-label={label}
		>
			{#if _isCopied === 'copied'}
				<span in:fade={{ duration: 150 }} class="flex items-center gap-2">
					<Check class="h-4 w-4 text-green-500" />
					<span class="sr-only">Copied!</span>
				</span>
			{:else if _isCopied === 'error'}
				<span in:fade={{ duration: 150 }} class="flex items-center gap-2">
					<X class="h-4 w-4 text-red-500" />
					<span class="sr-only">Failed to copy</span>
				</span>
			{:else}
				<span in:fade={{ duration: 150 }} class="flex items-center gap-2">
					<Copy class="h-4 w-4" />
					<span class="sr-only">{label}</span>
					{#if size !== 'icon'}
						<span>{label}</span>
					{/if}
				</span>

				<Tooltip.Content side="top">
					{label}
				</Tooltip.Content>
			{/if}
		</Button>
	</Tooltip.Trigger>
</Tooltip.Tooltip>
