<script lang="ts">
import { Button } from "$lib/components/ui/button";
import * as Tooltip from "$lib/components/ui/tooltip";
import { ChevronDown, ChevronUp, Edit } from "@lucide/svelte";
type Props = {
	memberId: string;
	isExpanded?: boolean;
	onToggleExpand?: () => void;
	showLabels?: boolean;
};
const {
	memberId,
	isExpanded = false,
	onToggleExpand,
	showLabels = false,
}: Props = $props();
</script>

<div
	class={showLabels
		? "grid w-full grid-cols-2 gap-2"
		: "flex justify-end gap-1"}
>
	<!-- Expander Button -->
	{#if onToggleExpand}
		{#if showLabels}
			<Button
				variant="outline"
				aria-expanded={isExpanded}
				onclick={onToggleExpand}
			>
				{#if isExpanded}
					<ChevronUp class="size-4" aria-hidden="true" />
					Hide details
				{:else}
					<ChevronDown class="size-4" aria-hidden="true" />
					View details
				{/if}
			</Button>
		{:else}
			<Tooltip.Root>
				<Tooltip.Trigger>
					{#snippet child({ props })}
						<Button
							variant="ghost"
							size="icon"
							aria-label={isExpanded
								? "Collapse member details"
								: "Expand member details"}
							aria-expanded={isExpanded}
							{...props}
							onclick={onToggleExpand}
						>
							{#if isExpanded}
								<ChevronUp class="size-4" aria-hidden="true" />
							{:else}
								<ChevronDown class="size-4" aria-hidden="true" />
							{/if}
						</Button>
					{/snippet}
				</Tooltip.Trigger>
				<Tooltip.Content>
					{isExpanded ? "Collapse details" : "Expand details"}
				</Tooltip.Content>
			</Tooltip.Root>
		{/if}
	{/if}
	{#if showLabels}
		<Button variant="ghost" href={`/dashboard/members/${memberId}`}>
			<Edit class="size-4" aria-hidden="true" />
			Edit member
		</Button>
	{:else}
		<Tooltip.Root>
			<Tooltip.Trigger>
				{#snippet child({ props })}
					<Button
						variant="ghost"
						size="icon"
						aria-label="Edit member details"
						href={`/dashboard/members/${memberId}`}
						{...props}
					>
						<Edit class="size-4" aria-hidden="true" />
					</Button>
				{/snippet}
			</Tooltip.Trigger>
			<Tooltip.Content>Edit member details</Tooltip.Content>
		</Tooltip.Root>
	{/if}
</div>
