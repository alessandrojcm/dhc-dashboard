<script lang="ts">
import CopyButton from "$lib/components/ui/copy-button.svelte";
import * as Tooltip from "$lib/components/ui/tooltip";
import { Button } from "$lib/components/ui/button";
import { SendIcon, Trash2 } from "@lucide/svelte";
import { cn } from "$lib/utils";

type Props = {
	resendInvitation: () => void;
	invitationLink: string;
	deleteInvitation: () => void;
	showLabels?: boolean;
	isResending?: boolean;
	isDeleting?: boolean;
};
const {
	resendInvitation,
	invitationLink,
	deleteInvitation,
	showLabels = false,
	isResending = false,
	isDeleting = false,
}: Props = $props();
</script>

<div
	class={showLabels
		? "grid grid-cols-3 gap-2 [&_button]:min-h-11"
		: "flex justify-end gap-1 [&_button]:size-11"}
>
	<CopyButton
		text={invitationLink}
		label={showLabels ? "Copy link" : "Copy invitation link"}
		size={showLabels ? "sm" : "icon"}
		variant={showLabels ? "outline" : "ghost"}
	/>
	<Tooltip.Root>
		<Tooltip.Trigger>
			{#snippet child({ props })}
				<Button
					variant="ghost"
					size={showLabels ? "sm" : "icon"}
					aria-label="Resend invitation email"
					{...props}
					disabled={isResending}
					class={cn(showLabels ? "min-h-11 min-w-0" : "size-11")}
					onclick={() => resendInvitation()}
				>
					<SendIcon class="size-4" aria-hidden="true" />
					{#if showLabels}
						<span>{isResending ? "Sending…" : "Resend"}</span>
					{/if}
				</Button>
			{/snippet}
		</Tooltip.Trigger>
		<Tooltip.Content>Resend invitation email</Tooltip.Content>
	</Tooltip.Root>
	<Tooltip.Root>
		<Tooltip.Trigger>
			{#snippet child({ props })}
				<Button
					variant={showLabels ? "destructive" : "ghost"}
					size={showLabels ? "sm" : "icon"}
					aria-label="Delete invitation"
					{...props}
					disabled={isDeleting}
					class={cn(
						showLabels ? "min-h-11 min-w-0" : "size-11 text-destructive",
					)}
					onclick={() => deleteInvitation()}
				>
					<Trash2 class="size-4" aria-hidden="true" />
					{#if showLabels}
						<span>{isDeleting ? "Deleting…" : "Delete"}</span>
					{/if}
				</Button>
			{/snippet}
		</Tooltip.Trigger>
		<Tooltip.Content>Delete invitation</Tooltip.Content>
	</Tooltip.Root>
</div>
