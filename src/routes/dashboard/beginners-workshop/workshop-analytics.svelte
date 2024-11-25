<script lang="ts">
	import type { SupabaseClient } from '@supabase/supabase-js';
	import type { Database } from '$database';
	im
	import * as Card from '$lib/components/ui/card/index.js';
	import * as Resizable from '$lib/components/ui/resizable/index.js';

	const { supabase }: { supabase: SupabaseClient<Database> } = $props();
	const totalCountQuery = createQuery<number>()
</script>
<h2 class="prose prose-h2 text-lg mb-2">Workshop analytics</h2>

{#snippet keyMetrics()}
	<Card.Root>
		<Card.Header>
			<Card.Title>Metrics</Card.Title>
		</Card.Header>
		<Card.Content class="grid grid-cols-2">
			<Card.Root class="bg-green-200 col-start-1">
				<Card.Header>
					<Card.Description class="text-black">Total waitlist</Card.Description>
				</Card.Header>
				<Card.Content>
					<p class="prose text-4xl">400</p>
				</Card.Content>
			</Card.Root>
		</Card.Content>
	</Card.Root>
{/snippet}

<Resizable.PaneGroup direction="horizontal">
	<Resizable.Pane minSize={30}>{@render keyMetrics()}</Resizable.Pane>
	<Resizable.Handle />
	<Resizable.Pane>Two</Resizable.Pane>
</Resizable.PaneGroup>
