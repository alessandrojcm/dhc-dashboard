<script lang="ts">
import { Button } from "$lib/components/ui/button";
import * as Tooltip from "$lib/components/ui/tooltip";
import { ChevronDown, ChevronUp, RotateCcw, SquarePen } from "@lucide/svelte";
import type { MemberStatus } from "./member-table.types";
type Props = {
	memberId: string;
	isExpanded?: boolean;
	onToggleExpand?: () => void;
	showLabels?: boolean;
	/** ALE-252: viewer holds a billing-authority role (minting pipeline). */
	canReactivate?: boolean;
	/** Row's membership status; the Reactivate action targets inactive rows. */
	membershipStatus?: MemberStatus | null;
	onReactivate?: () => void;
};
const {
	memberId,
	isExpanded = false,
	onToggleExpand,
	showLabels = false,
	canReactivate = false,
	membershipStatus = null,
	onReactivate,
}: Props = $props();

const showReactivate = $derived(
	canReactivate && membershipStatus === "inactive" && !!onReactivate,
);
</script>

<div
	class={showLabels
		? "grid w-full grid-cols-2 gap-2"
		: "flex justify-end gap-1"}
>
	{#if showReactivate}
		{#if showLabels}
			<Button variant="outline" onclick={() => onReactivate?.()}>
				<RotateCcw class="size-4" aria-hidden="true" />
				Reactivate
			</Button>
		{:else}
			<Tooltip.Root>
				<Tooltip.Trigger>
					{#snippet child({ props })}
						<Button
							variant="ghost"
							size="icon"
							aria-label="Reactivate membership"
							{...props}
							onclick={() => onReactivate?.()}
						>
							<RotateCcw class="size-4" aria-hidden="true" />
						</Button>
					{/snippet}
				</Tooltip.Trigger>
				<Tooltip.Content>Reactivate membership</Tooltip.Content>
			</Tooltip.Root>
		{/if}
	{/if}
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
			<SquarePen class="size-4" aria-hidden="true" />
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
						<SquarePen class="size-4" aria-hidden="true" />
					</Button>
				{/snippet}
			</Tooltip.Trigger>
			<Tooltip.Content>Edit member details</Tooltip.Content>
		</Tooltip.Root>
	{/if}
</div>
