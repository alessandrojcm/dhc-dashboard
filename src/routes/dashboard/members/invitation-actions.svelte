<script lang="ts">
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
			<Button
				variant="ghost"
				size="icon"
				aria-label="Resend invitation email"
				onclick={() => resendInvitation()}
			>
				<SendIcon class="h-4 w-4" />
			</Button>
		</Tooltip.Trigger>
		<Tooltip.Content>Resend invitation email</Tooltip.Content>
	</Tooltip.Root>
	<Tooltip.Root>
		<Tooltip.Trigger>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Delete invitation"
				onclick={() => deleteInvitation()}
			>
				<Trash2 class="h-4 w-4" />
			</Button>
		</Tooltip.Trigger>
		<Tooltip.Content>Delete invitation</Tooltip.Content>
	</Tooltip.Root>
</div>
