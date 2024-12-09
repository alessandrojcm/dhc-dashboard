<script lang="ts">
	import * as Tooltip from '$lib/components/ui/tooltip/index.js';
	import { Button } from '$lib/components/ui/button';
	import { Eye } from 'lucide-svelte';
	import { goto } from '$app/navigation';

	type Props = {
		memberId: string;
	};
	const { memberId }: Props = $props();
</script>

<Tooltip.Root>
	<Tooltip.Trigger>
		<Button
			variant="ghost"
			size="icon"
			aria-label="View member details"
			onclick={() => goto(`/dashboard/members/${memberId}`)}
		>
			<Eye class="h-4 w-4" />
		</Button>
	</Tooltip.Trigger>
	<Tooltip.Content>View member details</Tooltip.Content>
</Tooltip.Root>
