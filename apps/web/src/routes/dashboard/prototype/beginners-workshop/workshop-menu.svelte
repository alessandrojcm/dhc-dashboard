<!-- PROTOTYPE — throwaway (ALE-372). Workshop-level commands in one overflow menu. -->
<script lang="ts">
import { Ellipsis } from "@lucide/svelte";
import { Button } from "#lib/components/ui/button/index.js";
import * as DropdownMenu from "#lib/components/ui/dropdown-menu/index.js";
import { proto, type Workshop } from "./bw-prototype-store.svelte";

let {
	workshop: w,
	label = "Workshop",
}: { workshop: Workshop; label?: string } = $props();
const scheduled = $derived(w.status === "scheduled");
</script>

<DropdownMenu.Root>
	<DropdownMenu.Trigger>
		{#snippet child({ props })}
			<Button {...props} variant="outline"><Ellipsis /> {label}</Button>
		{/snippet}
	</DropdownMenu.Trigger>
	<DropdownMenu.Content align="end" class="w-60">
		<DropdownMenu.Item
			disabled={!scheduled}
			onSelect={() => {
				proto.dialog = { kind: "fast_track", workshopId: w.id };
			}}>Fast-track someone…</DropdownMenu.Item
		>
		<DropdownMenu.Item
			disabled={!scheduled}
			onSelect={() => {
				proto.dialog = { kind: "staff", workshopId: w.id };
			}}>Staff…</DropdownMenu.Item
		>
		<DropdownMenu.Item
			disabled={!scheduled}
			onSelect={() => {
				proto.dialog = { kind: "settings", workshopId: w.id };
			}}>Capacity, fee, Payment Cutoff…</DropdownMenu.Item
		>
		<DropdownMenu.Separator />
		<DropdownMenu.Item
			disabled={!scheduled}
			onSelect={() => {
				proto.dialog = { kind: "reschedule", workshopId: w.id };
			}}>Reschedule…</DropdownMenu.Item
		>
		<DropdownMenu.Item
			disabled={!scheduled}
			class="text-destructive"
			onSelect={() =>
				(proto.dialog = { kind: "cancel_workshop", workshopId: w.id })}
			>Cancel workshop…</DropdownMenu.Item
		>
	</DropdownMenu.Content>
</DropdownMenu.Root>
