<script lang="ts">
	import * as Popover from '$lib/components/ui/popover/index.js';
	import { Button } from '$lib/components/ui/button';
	import { NotebookPen, Edit, ChevronDown, ChevronUp, SendIcon } from 'lucide-svelte';
	import { Label } from '$lib/components/ui/label';
	import { Textarea } from '$lib/components/ui/textarea';
	import * as Tooltip from '$lib/components/ui/tooltip/index.js';

	type Props = {
		adminNotes: string;
		onEdit: (newValue: string) => void;
		isExpanded?: boolean;
		onToggleExpand?: () => void;
		inviteMember: () => void;
	};
	let isEdit = $state(false);
	const { adminNotes, onEdit, isExpanded = false, onToggleExpand, inviteMember }: Props = $props();
	let value = $state(adminNotes);
</script>

<div class="flex gap-w">
	<!-- Expander Button -->
	{#if onToggleExpand}
		<Button variant="ghost" size="icon" onclick={onToggleExpand} aria-label="Expand row">
			{#if isExpanded}
				<ChevronUp class="h-4 w-4" />
			{:else}
				<ChevronDown class="h-4 w-4" />
			{/if}
		</Button>
	{/if}
	<Tooltip.Root>
		<Tooltip.Trigger>
			<Button variant="ghost" aria-label="Invite Member" onclick={() => inviteMember()}>
				<SendIcon class="h-4 w-4" />
			</Button>
		</Tooltip.Trigger>
		<Tooltip.Content class="flex flex-col gap-y-2">
			<Label>Invite member</Label>
		</Tooltip.Content>
	</Tooltip.Root>

	<!-- Admin Notes -->
	<Popover.Root onOpenChange={(open) => !open && (isEdit = false)}>
		<Popover.Trigger>
			<Button variant="ghost" aria-label="Admin notes">
				<NotebookPen />
			</Button>
		</Popover.Trigger>
		<Popover.Content class="flex flex-col gap-y-2">
			<Label
				>Admin notes
				<Button variant="ghost" onclick={() => (isEdit = !isEdit)}>
					<Edit class="h-4 w-4" />
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
					>Save
				</Button>
			{:else}
				<p class="border border-solid border-black-200 rounded-md p-2 min-h-[5ch]">
					{value ?? 'N/A'}
				</p>
			{/if}
		</Popover.Content>
	</Popover.Root>
</div>
