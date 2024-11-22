<script lang="ts">
	import type { LayoutData } from './$types';
	import type { UserData } from '$lib/types';
	import { SidebarProvider } from '$lib/components/ui/sidebar';
	import DashboardSidebar from '$lib/components/ui/DashboardSidebar.svelte';
	import { page } from '$app/stores';
	import * as Breadcrumb from '$lib/components/ui/breadcrumb';
	import { Separator } from '$lib/components/ui/separator';
	import { QueryClient, QueryClientProvider } from '@tanstack/svelte-query';
	import { SvelteQueryDevtools } from '@tanstack/svelte-query-devtools';
	let { children, data }: { data: LayoutData; children: any } = $props();
	let supabase = $derived(data.supabase);
	let roles = $derived.by(() => new Set(data.roles));
	let paths = $derived.by(() => $page.url.pathname.split('/'));
	let userData = $derived.by(() => {
		return Promise.all([
			supabase
				.rpc('get_current_user_with_profile')
				.then(({ data }) => data as Omit<UserData, 'email'>),
			supabase.auth.getUser().then(({ data }) => data)
		]).then(
			([userData, sessionData]) =>
				({
					firstName: userData.firstName,
					lastName: userData.lastName,
					email: sessionData.user?.email!
				}) as UserData
		);
	});
	function getLink(item: string): string {
		let index = paths.indexOf(item);
		if (index === -1) {
			return '#';
		}
		return paths.slice(0, index + 1).join('/');
	}
	const queryClient = new QueryClient();
</script>

<svelte:head>
	<title>Dublin Hema Club - Dashboard</title>
</svelte:head>
<SidebarProvider>
	<DashboardSidebar {roles} logout={() => supabase.auth.signOut()} {userData} />
	<main class="w-full">
		<Breadcrumb.Root class="m-6">
			<Breadcrumb.List>
				{#each paths as item, index (item)}
					{#if index !== paths.length - 1}
						<Breadcrumb.Item>
							<Breadcrumb.Link class="capitalize" href={getLink(item)}>
								{item.replace('-', ' ')}
							</Breadcrumb.Link>
						</Breadcrumb.Item>
					{:else}
						<Breadcrumb.Item>
							<Breadcrumb.Page class="capitalize">
								<a href={getLink(item)}>{item.replace('-', ' ')}</a>
							</Breadcrumb.Page>
						</Breadcrumb.Item>
					{/if}
					{#if index < paths.length - 1}
						<Breadcrumb.Separator>/</Breadcrumb.Separator>
					{/if}
				{/each}
			</Breadcrumb.List>
		</Breadcrumb.Root>
		<Separator class="mb-2" />
		<QueryClientProvider client={queryClient}>
			{@render children()}
			<SvelteQueryDevtools />
		</QueryClientProvider>
	</main>
</SidebarProvider>

<style>
	main {
		flex: 1;
		display: flex;
		flex-direction: column;
		width: calc(100vw - var(--sidebar-width));
		margin: 0 auto;
		box-sizing: border-box;
		padding-bottom: 1rem;
	}
</style>
