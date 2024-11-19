<script lang="ts">
	import type { LayoutData } from './$types';
	import type { UserData } from '$lib/types';
	import { SidebarProvider } from '$lib/components/ui/sidebar';
	import DashboardSidebar from '$lib/components/ui/DashboardSidebar.svelte';
	import * as Breadcrumb from '$lib/components/ui/breadcrumb/index.js';
	import { Separator } from '$lib/components/ui/separator';

	let { children, data }: { data: LayoutData; children: any } = $props();
	let supabase = $derived(data.supabase);
	let roles = $derived.by(() => new Set(data.roles));
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
</script>

<svelte:head>
	<title>Dublin Hema Club - Dashboard</title>
</svelte:head>
<SidebarProvider>
	<DashboardSidebar {roles} logout={() => supabase.auth.signOut()} {userData} />
	<main class="w-full">
		<Breadcrumb.Root class="m-6">
			<Breadcrumb.List>
				<Breadcrumb.Item>
					<Breadcrumb.Page>Dashboard</Breadcrumb.Page>
				</Breadcrumb.Item>
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
		padding-bottom: 1rem;
	}
</style>
