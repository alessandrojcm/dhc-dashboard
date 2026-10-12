<script lang="ts">
import { createMutation } from "@tanstack/svelte-query";
import { waitlistUpdateStatusMutation } from "@dhc/api-client";
import { Lock, LockOpen, LoaderCircle } from "@lucide/svelte";
import { invalidate } from "$app/navigation";
import { toast } from "svelte-sonner";
import * as AlertDialog from "#lib/components/ui/alert-dialog/index.js";
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";
import { Button } from "#lib/components/ui/button/index.js";

let { isOpen }: { isOpen: boolean } = $props();
let dialogOpen = $state(false);
const toggle = createMutation(() => ({
	...waitlistUpdateStatusMutation(),
	onSuccess: () => {
		invalidate("wailist:status");
		toast.success("Waitlist status updated", { position: "top-center" });
		dialogOpen = false;
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Error updating waitlist status", {
			position: "top-center",
		});
		dialogOpen = false;
	},
}));
</script>

<AlertDialog.Root bind:open={dialogOpen}>
	<AlertDialog.Trigger>
		{#snippet child({ props })}
			<Button variant="outline" {...props}>
				{#if isOpen}<LockOpen aria-hidden="true" />{:else}<Lock
						aria-hidden="true"
					/>{/if}
				{isOpen ? "Close Waitlist" : "Open Waitlist"}
			</Button>
		{/snippet}
	</AlertDialog.Trigger>
	<WorkshopDialog alert>
		<AlertDialog.Header>
			<AlertDialog.Title>{isOpen ? "Close" : "Open"} waitlist</AlertDialog.Title
			>
			<AlertDialog.Description
				>Are you sure you want to {isOpen ? "close" : "open"} the waitlist? This action
				will affect new registrations.</AlertDialog.Description
			>
		</AlertDialog.Header>
		<AlertDialog.Footer>
			<AlertDialog.Cancel disabled={toggle.isPending}>Cancel</AlertDialog.Cancel
			>
			<AlertDialog.Action
				onclick={() => toggle.mutate({ body: { isOpen: !isOpen } })}
				disabled={toggle.isPending}
				data-testid="action"
			>
				{#if toggle.isPending}<LoaderCircle
						class="size-4 animate-spin motion-reduce:animate-none"
						aria-hidden="true"
					/>{/if}
				{isOpen ? "Close" : "Open"}
			</AlertDialog.Action>
		</AlertDialog.Footer>
	</WorkshopDialog>
</AlertDialog.Root>
