<script lang="ts">
	import type { LayoutData } from './$types';
	import type { UserData } from '$lib/types';
	import { SidebarProvider } from '$lib/components/ui/sidebar';
	import DashboardSidebar from '$lib/components/ui/DashboardSidebar.svelte';
	import { page } from '$app/state';
	import * as Breadcrumb from '$lib/components/ui/breadcrumb';
	import { Separator } from '$lib/components/ui/separator';
	import { createQuery } from '@tanstack/svelte-query';
	import { goto } from '$app/navigation';

	let { children, data }: { data: LayoutData; children: any } = $props();
	let supabase = $derived(data.supabase);
	let session = $derived(data.session);
	let roles = $derived.by(() => new Set(data.roles));
	let paths = $derived.by(() => page.url.pathname.split('/'));
	const userDataQuery = createQuery<UserData>(() => ({
		queryKey: ['logged_in_user_data'],
		experimental_prefetchInRender: true,
		enabled: true,
		queryFn: async ({ signal }) =>
			Promise.all([
				supabase.from('user_profiles').select('phone_number, customer_id').eq('supabase_user_id', session!.user?.id!).abortSignal(signal).single().then(({ data }) => ({ phoneNumber: data?.phone_number ?? '', customerId: data?.customer_id })),
				supabase
					.rpc('get_current_user_with_profile')
					.abortSignal(signal)
					.then(({ data }) => data as Omit<UserData, 'email' | 'phoneNumber' | 'customerId'>),
				supabase.auth.getUser().then(({ data }) => data)
			]).then(
				([profileData, userData, sessionData]) =>
					({
						firstName: userData.firstName,
						lastName: userData.lastName,
						email: sessionData.user?.email!,
						id: sessionData.user?.id!,
						phoneNumber: profileData.phoneNumber,
						customerId: profileData.customerId
					}) as UserData
			)
	}));

	function getLink(item: string): string {
		let index = paths.indexOf(item);
		if (index === -1) {
			return '#';
		}
		return paths.slice(0, index + 1).join('/');
	}
</script>

<svelte:head>
	<title>Dublin Hema Club - Dashboard</title>
</svelte:head>
<SidebarProvider class="h-[calc(100vh-5rem)]">
	<DashboardSidebar
		{roles}
		logout={async () => {
			await supabase.auth.signOut();
			goto('/auth', {
				replaceState: true,
				invalidateAll: true
			});
		}}
		userData={userDataQuery.promise}
		navData={data.navData}
		{supabase}
	/>
	<main class="w-full">
		<Breadcrumb.Root class="m-6">
			<Breadcrumb.List class="ml-12 md:ml-0">
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
								{item.replaceAll('-', ' ')}
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
		{@render children()}
	</main>
</SidebarProvider>

<style>
    main {
        flex: 1;
        display: flex;
        flex-direction: column;
        width: 100%;
        margin: 0 auto;
        box-sizing: border-box;
    }

    @media (min-width: 768px) {
        main {
            width: calc(100vw - var(--sidebar-width));
        }
    }
</style>
