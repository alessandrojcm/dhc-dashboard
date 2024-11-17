<script lang="ts">
	import Navbar from '$lib/components/ui/Navbar.svelte';
	import type { LayoutData } from './$types';
	import type { UserData } from '$lib/types';

	let { children, data }: { data: LayoutData; children: any } = $props();
	let supabase = $derived(data.supabase);
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
<Navbar logout={() => supabase.auth.signOut()} {userData} />
<main class="max-w-7xl">
	{@render children()}
</main>

<style>
	main {
		flex: 1;
		display: flex;
		flex-direction: column;
		width: 100%;
		margin: 0 auto;
		box-sizing: border-box;
		padding: 1rem;
	}
</style>
