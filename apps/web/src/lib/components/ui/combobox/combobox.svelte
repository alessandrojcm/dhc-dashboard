<!--
	A searchable select: the shadcn-svelte combobox composition (`Popover` +
	`Command`), which the registry documents as an example rather than ships
	as a component (ALE-379). Single selection closes on pick and offers a
	clear action; `multiple` keeps the list open and shows the picks as
	removable chips under the trigger.

	It submits nothing itself: the owning form renders its own hidden inputs
	from `value` (remote forms need `field.as(...)` names).
-->
<script lang="ts" module>
export type ComboboxItem = {
	value: string;
	label: string;
	/** A short tag shown beside the label (in the list and on a chip). */
	badge?: string;
};
</script>

<script lang="ts">
import Check from "@lucide/svelte/icons/check";
import ChevronsUpDown from "@lucide/svelte/icons/chevrons-up-down";
import X from "@lucide/svelte/icons/x";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Command from "#lib/components/ui/command/index.js";
import * as Popover from "#lib/components/ui/popover/index.js";
import { cn } from "#lib/utils.js";

let {
	id,
	label,
	items,
	value,
	onValueChange,
	multiple = false,
	placeholder,
	searchPlaceholder = "Search…",
	emptyText = "Nothing found.",
	clearLabel,
	disabled = false,
	class: className,
}: {
	id?: string;
	/** The accessible name of the trigger (and of the chip list). */
	label: string;
	items: ComboboxItem[];
	value: string[];
	onValueChange: (value: string[]) => void;
	multiple?: boolean;
	placeholder: string;
	searchPlaceholder?: string;
	emptyText?: string;
	/** Single selection only: the text of the action that clears the pick. */
	clearLabel?: string;
	disabled?: boolean;
	class?: string;
} = $props();

let open = $state(false);

const chosen = $derived(
	value.flatMap((selected) => items.filter((item) => item.value === selected)),
);

function toggle(itemValue: string) {
	if (!multiple) {
		onValueChange(value.includes(itemValue) ? [] : [itemValue]);
		open = false;
		return;
	}
	onValueChange(
		value.includes(itemValue)
			? value.filter((selected) => selected !== itemValue)
			: [...value, itemValue],
	);
}
</script>

<div class={cn("grid gap-2", className)}>
	<Popover.Root bind:open>
		<Popover.Trigger {disabled}>
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
					<span
						class={cn("truncate", !chosen.length && "text-muted-foreground")}
					>
						{#if !multiple && chosen[0]}
							{chosen[0].label}
						{:else if multiple && chosen.length}
							{chosen.length} selected
						{:else}
							{placeholder}
						{/if}
					</span>
					<ChevronsUpDown class="size-4 shrink-0 opacity-60" />
				</Button>
			{/snippet}
		</Popover.Trigger>
		<Popover.Content class="w-(--bits-popover-anchor-width) p-0" align="start">
			<Command.Root>
				<Command.Input placeholder={searchPlaceholder} />
				<Command.List>
					<Command.Empty>{emptyText}</Command.Empty>
					<Command.Group>
						{#each items as item (item.value)}
							<Command.Item
								value={`${item.label} ${item.value}`}
								keywords={[item.label]}
								onSelect={() => toggle(item.value)}
							>
								<Check
									class={cn(
										"size-4",
										value.includes(item.value) ? "opacity-100" : "opacity-0",
									)}
								/>
								<span class="flex-1">{item.label}</span>
								{#if item.badge}
									<Badge variant="outline" class="text-[10px]"
										>{item.badge}</Badge
									>
								{/if}
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
			aria-label={`Selected ${label.toLowerCase()}`}
		>
			{#each chosen as item (item.value)}
				<li>
					<Badge variant="outline" class="gap-1 py-1 pr-1">
						{item.label}{item.badge ? ` · ${item.badge}` : ""}
						<Button
							type="button"
							variant="ghost"
							size="icon"
							class="size-5 rounded-full"
							aria-label={`Remove ${item.label}`}
							{disabled}
							onclick={() => toggle(item.value)}
						>
							<X class="size-3" />
						</Button>
					</Badge>
				</li>
			{/each}
		</ul>
	{/if}
	{#if !multiple && chosen[0] && clearLabel}
		<Button
			type="button"
			variant="link"
			size="sm"
			class="h-auto w-fit p-0 text-xs text-muted-foreground"
			{disabled}
			onclick={() => onValueChange([])}
		>
			{clearLabel}
		</Button>
	{/if}
</div>
