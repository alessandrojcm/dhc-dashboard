<script lang="ts">
	import * as Tooltip from '$lib/components/ui/tooltip/index.js';
	import { Button } from '$lib/components/ui/button';
	import { Ambulance, Edit } from 'lucide-svelte';

	type Props = {
		memberId: string;
		userId: string;
		setSelectedUserId: (id: string) => void;
	};
	let { memberId, userId, setSelectedUserId }: Props = $props();
</script>

<Tooltip.Root>
	<Tooltip.Trigger>
		<Button
			variant="ghost"
			size="icon"
			aria-label="View member Emergency Contact"
			onclick={() => setSelectedUserId(userId)}
		>
			<Ambulance class="h-4 w-4" />
		</Button>
	</Tooltip.Trigger>
	<Tooltip.Content>View member emergency contact</Tooltip.Content>
</Tooltip.Root>
<Tooltip.Root>
	<Tooltip.Trigger>
		<Button
			variant="ghost"
			size="icon"
			aria-label="Edit member details"
			href={`/dashboard/members/${memberId}`}
		>
			<Edit class="h-4 w-4" />
		</Button>
	</Tooltip.Trigger>
	<Tooltip.Content>Edit member details</Tooltip.Content>
</Tooltip.Root>
