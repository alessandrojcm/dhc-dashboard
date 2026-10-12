<!-- PROTOTYPE — throwaway (ALE-372). Searchable Member picker for Beginners' Workshop Staff.
     The coach picker passes only coach-role Members; the assistants picker passes every
     active Member (coaches included, so one coach can lead and another assist). -->
<script lang="ts">
import { Check, ChevronsUpDown, X } from "@lucide/svelte";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Command from "#lib/components/ui/command/index.js";
import * as Popover from "#lib/components/ui/popover/index.js";
import type { StaffMember } from "./bw-prototype-store.svelte";

let {
	id,
	label,
	members,
	selected,
	multiple = false,
	placeholder,
	onChange,
}: {
	id: string;
	label: string;
	members: StaffMember[];
	selected: string[];
	multiple?: boolean;
	placeholder: string;
	onChange: (ids: string[]) => void;
} = $props();

let open = $state(false);
const chosen = $derived(
	selected.flatMap((memberId) =>
		members.filter((member) => member.id === memberId),
	),
);

function toggle(memberId: string) {
	if (!multiple) {
		onChange(selected.includes(memberId) ? [] : [memberId]);
		open = false;
		return;
	}
	onChange(
		selected.includes(memberId)
			? selected.filter((candidate) => candidate !== memberId)
			: [...selected, memberId],
	);
}
</script>

<div class="grid gap-2">
	<Popover.Root bind:open>
		<Popover.Trigger>
			{#snippet child({ props })}
				<Button
					{...props}
					{id}
					variant="outline"
					role="combobox"
					aria-expanded={open}
					aria-label={label}
					class="w-full justify-between font-normal"
				>
					<span class="truncate {chosen.length ? '' : 'text-muted-foreground'}">
						{#if !multiple && chosen[0]}{chosen[0]
								.name}{:else if multiple && chosen.length}{chosen.length} selected{:else}{placeholder}{/if}
					</span>
					<ChevronsUpDown class="size-4 shrink-0 opacity-60" />
				</Button>
			{/snippet}
		</Popover.Trigger>
		<Popover.Content class="w-(--bits-popover-anchor-width) p-0" align="start">
			<Command.Root>
				<Command.Input placeholder="Search Members…" />
				<Command.List>
					<Command.Empty>No Member found.</Command.Empty>
					<Command.Group>
						{#each members as member (member.id)}
							<Command.Item
								value={member.name}
								onSelect={() => toggle(member.id)}
							>
								<Check
									class="size-4 {selected.includes(member.id)
										? 'opacity-100'
										: 'opacity-0'}"
								/>
								<span class="flex-1">{member.name}</span>
								{#if member.isCoach}<Badge variant="outline" class="text-[10px]"
										>coach</Badge
									>{/if}
							</Command.Item>
						{/each}
					</Command.Group>
				</Command.List>
			</Command.Root>
		</Popover.Content>
	</Popover.Root>
	{#if multiple && chosen.length}
		<ul
			class="flex flex-wrap gap-1.5"
			aria-label="Selected {label.toLowerCase()}"
		>
			{#each chosen as member (member.id)}
				<li>
					<Badge variant="outline" class="gap-1 py-1 pr-1">
						{member.name}{member.isCoach ? " · coach" : ""}
						<button
							type="button"
							class="cursor-pointer rounded-full p-0.5 hover:bg-muted"
							aria-label="Remove {member.name}"
							onclick={() => toggle(member.id)}><X class="size-3" /></button
						>
					</Badge>
				</li>
			{/each}
		</ul>
	{/if}
	{#if !multiple && chosen[0]}
		<button
			type="button"
			class="w-fit cursor-pointer text-xs text-muted-foreground underline-offset-2 hover:underline"
			onclick={() => onChange([])}>Clear coach (Unstaffed)</button
		>
	{/if}
</div>
