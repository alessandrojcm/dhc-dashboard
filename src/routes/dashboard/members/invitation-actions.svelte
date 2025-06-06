<script lang="ts">
	import * as Tooltip from '$lib/components/ui/tooltip/index.js';
	import { Button } from '$lib/components/ui/button';
	import { SendIcon } from 'lucide-svelte';
	import CopyButton from '$lib/components/ui/copy-button.svelte';

	type Props = {
		resendInvitation: () => void;
		invitationLink: string;
	};
	let { resendInvitation, invitationLink }: Props = $props();
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
</div>
