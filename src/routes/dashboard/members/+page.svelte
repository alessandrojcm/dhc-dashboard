<script lang="ts">
	import * as Tabs from '$lib/components/ui/tabs/index.js';
	import Analytics from './member-analytics.svelte';
	import MembersTable from './members-table.svelte';
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import SettingsSheet from './settings-sheet.svelte';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';

	const { data } = $props();
	let value = $derived.by(() => $page.url.searchParams.get('tab') || 'dashboard');

	function onTabChagne(value: string) {
		const newParams = new URLSearchParams($page.url.searchParams);
		newParams.set('tab', value);
		goto(`/dashboard/members?${newParams.toString()}`);
	}
</script>

<div class="relative">
	{#if data.canEditSettings}
		{#await data.form}
			<div class="fixed right-4 top-4">
				<LoaderCircle />
			</div>
		{:then form}
			<SettingsSheet {form} />
		{/await}
	{/if}

	<Tabs.Root {value} onValueChange={onTabChagne} class="p-2 min-h-96 mr-2">
		<Tabs.List>
			<Tabs.Trigger value="dashboard">Dashboard</Tabs.Trigger>
			<Tabs.Trigger value="members">Members list</Tabs.Trigger>
		</Tabs.List>
		<Tabs.Content value="dashboard">
			<Analytics supabase={data.supabase} />
		</Tabs.Content>
		<Tabs.Content value="members">
			<MembersTable supabase={data.supabase} />
		</Tabs.Content>
	</Tabs.Root>
</div>
