<script lang="ts">
	/* eslint-disable @typescript-eslint/no-explicit-any */
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { Root, List, Trigger, Content } from '$lib/components/ui/tabs/index.js';
	import InviteDrawer from './invite-drawer.svelte';
	import Analytics from './member-analytics.svelte';
	import MembersTable from './members-table.svelte';
	import InvitationsTable from './invitations-table.svelte';
	import SettingsSheet from './settings-sheet.svelte';
	import * as Select from '$lib/components/ui/select';

	const { data } = $props();
	let value = $derived(page.url.searchParams.get('tab') || 'dashboard');

	function onTabChange(value: string) {
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const newParams = new URLSearchParams(page.url.searchParams);
		newParams.set('tab', value);
		const url = `/dashboard/members?${newParams.toString()}`;
		goto(resolve(url as any));
	}
	let views = [
		{
			id: 'dashboard',
			label: 'Dashboard'
		},
		{
			id: 'members',
			label: 'Members list'
		},
		{
			id: 'invitations',
			label: 'Invitations'
		}
	];
	let viewLabel = $derived(views.find((view) => view.id === value)?.label || 'Dashboard');
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

	<Root {value} onValueChange={onTabChange} class="p-2 min-h-96 mr-2">
		<div class="flex justify-between items-center mb-2">
			<Select.Root {value} type="single" onValueChange={onTabChange}>
				<Select.Trigger class="md:hidden flex w-fit" size="sm" id="view-selector">
					{viewLabel}
				</Select.Trigger>
				<Select.Content>
					{#each views as view (view.id)}
						<Select.Item value={view.id}>{view.label}</Select.Item>
					{/each}
				</Select.Content>
			</Select.Root>
			<List class="md:flex hidden">
				<Trigger value="dashboard">Dashboard</Trigger>
				<Trigger value="members">Members list</Trigger>
				<Trigger value="invitations">Invitations</Trigger>
			</List>

			{#if data.canEditSettings}
				<InviteDrawer supabase={data.supabase} />
			{/if}
		</div>
		<Content value="dashboard">
			<Analytics supabase={data.supabase} />
		</Content>
		<Content value="members">
			<MembersTable supabase={data.supabase} />
		</Content>
		<Content value="invitations">
			<InvitationsTable supabase={data.supabase} />
		</Content>
	</Root>
</div>
