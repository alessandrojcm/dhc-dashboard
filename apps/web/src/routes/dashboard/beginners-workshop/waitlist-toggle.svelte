<script lang="ts">
import { createMutation } from "@tanstack/svelte-query";
import { waitlistUpdateStatusMutation } from "@dhc/api-client";
import { Lock, LockOpen, LoaderCircle } from "@lucide/svelte";
import { invalidate } from "$app/navigation";
import { toast } from "svelte-sonner";
import * as AlertDialog from "#lib/components/ui/alert-dialog/index.js";
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";
import { Badge } from "#lib/components/ui/badge/index.js";
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

<div class="flex items-center gap-3">
	<!-- The badge states where the waitlist is; the button names what pressing it does. -->
	<Badge variant="outline" class="gap-1.5 px-2.5 py-1 text-sm">
		<span
			class={[
				"size-2 rounded-full",
				isOpen ? "bg-primary" : "bg-muted-foreground",
			]}
			aria-hidden="true"
		></span>
		{isOpen ? "Waitlist open" : "Waitlist closed"}
	</Badge>
	<AlertDialog.Root bind:open={dialogOpen}>
		<AlertDialog.Trigger>
			{#snippet child({ props })}
				<Button variant="outline" {...props}>
					{#if isOpen}<Lock aria-hidden="true" />{:else}<LockOpen
							aria-hidden="true"
						/>{/if}
					{isOpen ? "Close" : "Open"}<span class="sr-only"> waitlist</span>
				</Button>
			{/snippet}
		</AlertDialog.Trigger>
		<WorkshopDialog alert>
			<AlertDialog.Header>
				<AlertDialog.Title
					>{isOpen ? "Close" : "Open"} the waitlist?</AlertDialog.Title
				>
				<AlertDialog.Description
					>{isOpen
						? "New people won't be able to join the waitlist until you open it again. People already on it keep their place."
						: "New people will be able to join the waitlist from the public sign-up page."}</AlertDialog.Description
				>
			</AlertDialog.Header>
			<AlertDialog.Footer>
				<AlertDialog.Cancel disabled={toggle.isPending}
					>Cancel</AlertDialog.Cancel
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
</div>
