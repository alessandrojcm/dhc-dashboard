<script lang="ts">
import { Button } from "#lib/components/ui/button/index.js";
import {
	ChevronUp,
	ChevronDown,
	SquarePen,
	NotebookPen,
	Undo2,
	UserMinus,
} from "@lucide/svelte";
import * as Popover from "#lib/components/ui/popover/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";

type Props = {
	adminNotes: string;
	onEdit: (newValue: string) => void;
	isExpanded?: boolean;
	onToggleExpand?: () => void;
	/** Offered only for a person removed within the restore window. */
	onRestore?: () => void;
	restoreDisabled?: boolean;
	/** ALE-387: offered for someone still on the Waitlist. */
	onWithdraw?: () => void;
};
let isEdit = $state(false);
let {
	adminNotes,
	onEdit,
	isExpanded = false,
	onToggleExpand,
	onRestore,
	restoreDisabled = false,
	onWithdraw,
}: Props = $props();
let value = $state(adminNotes);
</script>

<div class="flex gap-w">
	<!-- Expander Button -->
	{#if onToggleExpand}
		<Button
			variant="ghost"
			size="icon"
			onclick={onToggleExpand}
			aria-label="Expand row"
		>
			{#if isExpanded}
				<ChevronUp class="h-4 w-4" />
			{:else}
				<ChevronDown class="h-4 w-4" />
			{/if}
		</Button>
	{/if}
	{#if onRestore}
		<Button
			variant="ghost"
			onclick={onRestore}
			disabled={restoreDisabled}
			aria-label="Restore to the Waitlist"
			title="Restore to the Waitlist with their original date"
		>
			<Undo2 class="h-4 w-4" />
			Restore
		</Button>
	{/if}
	{#if onWithdraw}
		<Button
			variant="ghost"
			onclick={onWithdraw}
			aria-label="Withdraw from the Waitlist"
			title="Withdraw from the Waitlist"
		>
			<UserMinus class="h-4 w-4" />
		</Button>
	{/if}
	<!-- Admin Notes -->
	<Popover.Root onOpenChange={(open) => !open && (isEdit = false)}>
		<Popover.Trigger>
			{#snippet child({ props })}
				<Button variant="ghost" aria-label="Admin notes" {...props}>
					<NotebookPen />
				</Button>
			{/snippet}
		</Popover.Trigger>
		<Popover.Content class="flex flex-col gap-y-2">
			<Label
				>Admin notes
				<Button variant="ghost" onclick={() => (isEdit = !isEdit)}>
					<SquarePen class="h-4 w-4" />
				</Button>
			</Label>
			{#if isEdit}
				<Textarea class="min-h-[5ch]" bind:value />
				<Button
					class="self-start"
					onclick={() => {
						onEdit(value);
						isEdit = false;
					}}
				>
					Save
				</Button>
			{:else}
				<p
					class="border border-solid border-black-200 rounded-md p-2 min-h-[5ch]"
				>
					{value ?? "N/A"}
				</p>
			{/if}
		</Popover.Content>
	</Popover.Root>
</div>
