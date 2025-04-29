<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { Root, List, Trigger, Content } from '$lib/components/ui/tabs/index.js';
	import InviteDrawer from './invite-drawer.svelte';
	import Analytics from './member-analytics.svelte';
	import MembersTable from './members-table.svelte';
	import SettingsSheet from './settings-sheet.svelte';

	const { data } = $props();
	let value = $state(page.url.searchParams.get('tab') || 'dashboard');

	function onTabChagne(value: string) {
		const newParams = new URLSearchParams(page.url.searchParams);
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

	<Root {value} onValueChange={onTabChagne} class="p-2 min-h-96 mr-2">
		<div class="flex justify-between items-center mb-2">
			<List>
				<Trigger value="dashboard">Dashboard</Trigger>
				<Trigger value="members">Members list</Trigger>
			</List>

			{#if data.canEditSettings}
				<InviteDrawer supabase={data.supabase} />
			{/if}
		</div>
<!-- how to import the analytics... -->
		<Content value="dashboard">
			<Analytics supabase={data.supabase} />
		</Content>
		<Content value="members">
			<MembersTable supabase={data.supabase} />
		</Content>
	</Root>
</div>
