<script lang="ts">
import { Button } from "$lib/components/ui/button";
import * as Tooltip from "$lib/components/ui/tooltip";
import { ChevronDown, ChevronUp, Edit } from "lucide-svelte";
type Props = {
	memberId: string;
	isExpanded?: boolean;
	onToggleExpand?: () => void;
};
const { memberId, isExpanded = false, onToggleExpand }: Props = $props();
</script>

<div class="flex gap-1">
	<!-- Expander Button -->
	{#if onToggleExpand}
		<Tooltip.Root>
			<Tooltip.Trigger>
				<Button
					variant="ghost"
					size="icon"
					class="h-8 w-8"
					onclick={onToggleExpand}
					aria-label="Expand row"
				>
					{#if isExpanded}
						<ChevronUp class="h-4 w-4" />
					{:else}
						<ChevronDown class="h-4 w-4" />
					{/if}
				</Button>
			</Tooltip.Trigger>
			<Tooltip.Content
				>{isExpanded
					? "Collapse details"
					: "Expand details"}</Tooltip.Content
			>
		</Tooltip.Root>
	{/if}
	<Tooltip.Root>
		<Tooltip.Trigger>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Edit member details"
				href={`/dashboard/members/${memberId}`}
			>
				<Edit class="h-4 w-4" />
			</Button>
		</Tooltip.Trigger>
		<Tooltip.Content>Edit member details</Tooltip.Content>
	</Tooltip.Root>
</div>
