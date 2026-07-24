<script lang="ts">
import CopyButton from "$lib/components/ui/copy-button.svelte";
import * as Tooltip from "$lib/components/ui/tooltip";
import { Button } from "$lib/components/ui/button";
import { SendIcon, Trash2 } from "lucide-svelte";

type Props = {
	resendInvitation: () => void;
	invitationLink: string;
	deleteInvitation: () => void;
};
const { resendInvitation, invitationLink, deleteInvitation }: Props = $props();
</script>

<div class="flex gap-1">
	<CopyButton text={invitationLink} label="Copy invitation link" />
	<Tooltip.Root>
		<Tooltip.Trigger>
			{#snippet child({ props })}
				<Button
					variant="ghost"
					size="icon"
					aria-label="Resend invitation email"
					{...props}
					onclick={() => resendInvitation()}
				>
					<SendIcon class="h-4 w-4" />
				</Button>
			{/snippet}
		</Tooltip.Trigger>
		<Tooltip.Content>Resend invitation email</Tooltip.Content>
	</Tooltip.Root>
	<Tooltip.Root>
		<Tooltip.Trigger>
			{#snippet child({ props })}
				<Button
					variant="ghost"
					size="icon"
					aria-label="Delete invitation"
					{...props}
					onclick={() => deleteInvitation()}
				>
					<Trash2 class="h-4 w-4" />
				</Button>
			{/snippet}
		</Tooltip.Trigger>
		<Tooltip.Content>Delete invitation</Tooltip.Content>
	</Tooltip.Root>
</div>
