<script lang="ts">
import CheckIcon from "@lucide/svelte/icons/check";
import MinusIcon from "@lucide/svelte/icons/minus";
import { cn } from "$lib/utils";

type Props = {
	checked: boolean;
	indeterminate?: boolean;
	label: string;
	onCheckedChange: (checked: boolean) => void;
};

const {
	checked,
	indeterminate = false,
	label,
	onCheckedChange,
}: Props = $props();
</script>

<button
	type="button"
	role="checkbox"
	aria-checked={indeterminate ? "mixed" : checked}
	aria-label={label}
	class="flex size-11 cursor-pointer touch-manipulation items-center justify-center rounded-md outline-none transition-colors duration-200 hover:bg-muted focus-visible:ring-[3px] focus-visible:ring-ring/50"
	onclick={() => onCheckedChange(!checked)}
>
	<span
		aria-hidden="true"
		class={cn(
			"flex size-4 items-center justify-center rounded-[4px] border border-input bg-background text-primary-foreground shadow-xs transition-[background-color,border-color] duration-200",
			(checked || indeterminate) && "border-primary bg-primary",
		)}
	>
		{#if indeterminate}
			<MinusIcon class="size-3.5" />
		{:else if checked}
			<CheckIcon class="size-3.5" />
		{/if}
	</span>
</button>
