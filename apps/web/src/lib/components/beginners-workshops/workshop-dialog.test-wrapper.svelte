<script lang="ts">
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as AlertDialog from "#lib/components/ui/alert-dialog/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import WorkshopDialog from "./workshop-dialog.svelte";

let { alert = false }: { alert?: boolean } = $props();
let open = $state(false);
</script>

{#if alert}
	<AlertDialog.Root bind:open>
		<AlertDialog.Trigger>Change waitlist</AlertDialog.Trigger>
		<WorkshopDialog alert>
			<AlertDialog.Header>
				<AlertDialog.Title>Close waitlist?</AlertDialog.Title>
				<AlertDialog.Description
					>Only new registrations are affected.</AlertDialog.Description
				>
			</AlertDialog.Header>
			<AlertDialog.Footer>
				<AlertDialog.Cancel>Keep open</AlertDialog.Cancel>
				<AlertDialog.Action>Close waitlist</AlertDialog.Action>
			</AlertDialog.Footer>
		</WorkshopDialog>
	</AlertDialog.Root>
{:else}
	<Label for="reference-input">Reference input</Label>
	<Input id="reference-input" placeholder="Enter a value" />
	<Dialog.Root bind:open>
		<Dialog.Trigger>Open workshop form</Dialog.Trigger>
		<WorkshopDialog>
			<Dialog.Header>
				<Dialog.Title>Workshop details</Dialog.Title>
				<Dialog.Description
					>Review the details before saving.</Dialog.Description
				>
			</Dialog.Header>
			<form class="grid gap-5" onsubmit={(event) => event.preventDefault()}>
				{#each Array.from({ length: 15 }, (_, index) => index) as index (index)}
					<div class="grid gap-2">
						<Label for={`detail-${index}`}>Detail {index + 1}</Label>
						<Input id={`detail-${index}`} placeholder="Enter a value" />
					</div>
				{/each}
				<Dialog.Footer>
					<Button variant="outline" onclick={() => (open = false)}
						>Cancel</Button
					>
					<Button type="submit">Save details</Button>
				</Dialog.Footer>
			</form>
		</WorkshopDialog>
	</Dialog.Root>
{/if}
