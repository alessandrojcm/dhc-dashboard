<script lang="ts">
/* eslint-disable @typescript-eslint/no-explicit-any */
import type { LayoutData } from "./$types";
import { SidebarProvider } from "$lib/components/ui/sidebar";
import DashboardSidebar from "$lib/components/ui/DashboardSidebar.svelte";
import { page } from "$app/state";
import * as Breadcrumb from "$lib/components/ui/breadcrumb";
import { Separator } from "$lib/components/ui/separator";
import { createQuery } from "@tanstack/svelte-query";
import { goto } from "$app/navigation";
import { invalidateAll, invalidate } from "$app/navigation";
import { resolve } from "$app/paths";
import { membersMeOptions, authDeleteSession } from "@dhc/api-client";

let { children, data }: { data: LayoutData; children: any } = $props();
let roles = $derived.by(() => new Set(data.roles));
let paths = $derived.by(() => page.url.pathname.split("/"));
const userDataQuery = createQuery(() => ({
	...membersMeOptions(),
	experimental_prefetchInRender: true,
	enabled: true,
	select: (response) => ({
		firstName: response.data.firstName,
		lastName: response.data.lastName,
		email: response.data.email,
		id: response.data.id,
		phoneNumber: response.data.phoneNumber ?? "",
		customerId: response.data.customerId ?? undefined,
	}),
}));

/**
 * ALE-164: sign out via `DELETE /api/auth/session` (Phoenix revokes the
 * session token and clears the `_dhc_session` cookie). The generated
 * client sends the cookie with `credentials: 'include'`; no Supabase
 * `auth.signOut()` call remains.
 */
async function logout() {
	try {
		await authDeleteSession();
	} catch {
		// Even if Phoenix is unreachable, clear the local session and
		// redirect — the cookie will expire on its own.
	}
	await invalidateAll();
	await invalidate("phoenix:session");
	await goto(resolve("/auth"), {
		replaceState: true,
		invalidateAll: true,
	});
}

function getLink(item: string): string {
	let index = paths.indexOf(item);
	if (index === -1) {
		return "#";
	}
	return paths.slice(0, index + 1).join("/");
}
</script>

<svelte:head>
	<title>Dublin Hema Club - Dashboard</title>
</svelte:head>
<SidebarProvider class="h-[calc(100vh-5rem)]">
	<DashboardSidebar
		{roles}
		{logout}
		userData={userDataQuery.promise}
		navData={data.navData}
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
