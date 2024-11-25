<script lang="ts">
	import * as Popover from '$lib/components/ui/popover/index.js';
	import * as Tooltip from '$lib/components/ui/tooltip/index.js';
	import { Button } from '$lib/components/ui/button';
	import { BriefcaseMedical, NotebookPen, Edit } from 'lucide-svelte';
	import { Label } from '$lib/components/ui/label';
	import { Textarea } from '$lib/components/ui/textarea';
	type Props = {
		medicalConditions: string;
		adminNotes: string;
		onEdit: (newValue: string) => void;
	};
	let isEdit = $state(false);
	const { medicalConditions, adminNotes, onEdit }: Props = $props();
	let value = $state(adminNotes);
</script>

<div class="flex gap-w">
	<Tooltip.Root>
		<Tooltip.Trigger>
			<Button variant="ghost" aria-label="Medical conditions" class="text-red-500">
				<BriefcaseMedical />
			</Button>
		</Tooltip.Trigger>
		<Tooltip.Content>{medicalConditions}</Tooltip.Content>
	</Tooltip.Root>
	<Popover.Root onOpenChange={(open) => !open && (isEdit = false)}>
		<Popover.Trigger>
			<Button variant="ghost" aria-label="Admin notes" class="text-blue-500">
				<NotebookPen />
			</Button>
		</Popover.Trigger>
		<Popover.Content class="flex flex-col gap-y-2">
			<Label
				>Admin notes <Button variant="ghost" onclick={() => (isEdit = !isEdit)}><Edit /></Button
				></Label
			>
			{#if isEdit}
				<Textarea class="min-h-[5ch]" bind:value />
				<Button
					class="self-start"
					onclick={() => {
						onEdit(value);
						isEdit = false;
					}}>Save</Button
				>
			{:else}
				<p class="border border-solid border-black-200 rounded-md p-2 min-h-[5ch]">
					{value ?? 'N/A'}
				</p>
			{/if}
		</Popover.Content>
	</Popover.Root>
</div>
