<script lang="ts">
	import WaitlistTable from './waitlist-table.svelte';
	import Analytics from './workshop-analytics.svelte'
	import * as Tabs from '$lib/components/ui/tabs/index.js';

	const { data } = $props();
	const supabase = data.supabase;
	let value = $state('dashboard')
</script>
<Tabs.Root bind:value  class="p-2 min-h-96 mr-2">
	<Tabs.List>
		<Tabs.Trigger value="dashboard">Dashboard</Tabs.Trigger>
		<Tabs.Trigger value="waitlist">Waitlist</Tabs.Trigger>
	</Tabs.List>
	<Tabs.Content value="dashboard">
		<Analytics {supabase} />
	</Tabs.Content>
	<Tabs.Content value="waitlist">
		<WaitlistTable {supabase} />
	</Tabs.Content>
</Tabs.Root>
