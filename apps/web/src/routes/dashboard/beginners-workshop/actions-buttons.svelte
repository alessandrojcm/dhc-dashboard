<script lang="ts">
import { Button, buttonVariants } from "#lib/components/ui/button/index.js";
import {
	ChevronDown,
	Ellipsis,
	SquarePen,
	NotebookPen,
	Undo2,
	UserMinus,
	Trash2,
} from "@lucide/svelte";
import * as DropdownMenu from "#lib/components/ui/dropdown-menu/index.js";
import * as Popover from "#lib/components/ui/popover/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";

type Props = {
	/** The person's name, for the "⋯" menu's accessible name. */
	name: string;
	adminNotes: string;
	onEdit: (newValue: string) => void;
	/**
	 * Which controls to render: the desktop table puts the expand toggle in
	 * its first column and the rest at the row's end; a card renders both.
	 */
	part?: "expand" | "tools" | "all";
	isExpanded?: boolean;
	onToggleExpand?: () => void;
	/** Each action is passed only when Phoenix offers it (ALE-417). */
	onRestore?: () => void;
	restoreDisabled?: boolean;
	/** ALE-387. */
	onWithdraw?: () => void;
	/** ALE-396: a hard delete. */
	onDelete?: () => void;
};
let isEdit = $state(false);
let {
	name,
	adminNotes,
	onEdit,
	part = "all",
	isExpanded = false,
	onToggleExpand,
	onRestore,
	restoreDisabled = false,
	onWithdraw,
	onDelete,
}: Props = $props();
// svelte-ignore state_referenced_locally
let value = $state(adminNotes);
const showExpand = $derived(part !== "tools");
const showTools = $derived(part !== "expand");
</script>

<div class="flex items-center gap-1">
	{#if showExpand && onToggleExpand}
		<Button
			variant="ghost"
			size="icon"
			onclick={onToggleExpand}
			aria-label="Expand row"
			aria-expanded={isExpanded}
		>
			<ChevronDown
				class={[
					"size-4 transition-transform duration-150 ease-[cubic-bezier(0.23,1,0.32,1)] motion-reduce:transition-none",
					isExpanded && "rotate-180",
				]}
			/>
		</Button>
	{/if}
	{#if showTools}
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
		<!-- Admin Notes -->
		<Popover.Root onOpenChange={(open) => !open && (isEdit = false)}>
			<Popover.Trigger>
				{#snippet child({ props })}
					<Button
						variant="ghost"
						size="icon"
						aria-label="Admin notes"
						title="Admin notes"
						{...props}
					>
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
		<!-- Withdraw and Delete sit behind a menu, away from the row's everyday controls. -->
		{#if onWithdraw || onDelete}
			<DropdownMenu.Root>
				<DropdownMenu.Trigger
					class={buttonVariants({ variant: "ghost", size: "icon" })}
					aria-label={`More actions for ${name}`}
				>
					<Ellipsis class="size-4" />
				</DropdownMenu.Trigger>
				<DropdownMenu.Content align="end" class="w-56">
					{#if onWithdraw}
						<DropdownMenu.Item onSelect={onWithdraw}>
							<UserMinus />Withdraw from the Waitlist
						</DropdownMenu.Item>
					{/if}
					{#if onWithdraw && onDelete}
						<DropdownMenu.Separator />
					{/if}
					{#if onDelete}
						<DropdownMenu.Item variant="destructive" onSelect={onDelete}>
							<Trash2 />Delete this person
						</DropdownMenu.Item>
					{/if}
				</DropdownMenu.Content>
			</DropdownMenu.Root>
		{/if}
	{/if}
</div>
