<script lang="ts">
import type { LayoutData } from "./$types";
import { SidebarProvider } from "$lib/components/ui/sidebar";
import DashboardSidebar from "$lib/components/ui/DashboardSidebar.svelte";
import { page } from "$app/state";
import * as Breadcrumb from "$lib/components/ui/breadcrumb";
import { createQuery } from "@tanstack/svelte-query";
import { goto } from "$app/navigation";
import { invalidateAll, invalidate } from "$app/navigation";
import { resolve } from "$app/paths";
import { membersMeOptions, authDeleteSession } from "@dhc/api-client";
import type { Snippet } from "svelte";

let { children, data }: { data: LayoutData; children: Snippet } = $props();
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

function getBreadcrumbLabel(item: string, index: number): string {
	const isMemberProfile =
		page.route.id === "/dashboard/members/[memberId]" &&
		index === paths.length - 1;
	if (isMemberProfile) {
		return userDataQuery.data?.id === page.params.memberId
			? "My profile"
			: "Member profile";
	}
	return item.replaceAll("-", " ");
}
</script>

<svelte:head>
	<title>Dublin Hema Club - Dashboard</title>
</svelte:head>
<a
	href="#dashboard-content"
	class="sr-only z-50 rounded-md bg-primary px-4 py-3 text-primary-foreground focus:fixed focus:left-4 focus:top-4 focus:not-sr-only"
	>Skip to dashboard content</a
>
<SidebarProvider class="min-h-svh bg-background">
	<DashboardSidebar
		{roles}
		{logout}
		userData={userDataQuery.promise}
		navData={data.navData}
	/>
	<main id="dashboard-content" class="min-w-0 w-full">
		<header
			class="sticky top-0 z-20 border-b border-border/70 bg-background/90 px-4 py-3 backdrop-blur-md sm:px-6"
		>
			<div class="mx-auto flex max-w-[90rem] items-center gap-4">
				<div
					class="ml-12 hidden border-r border-border pr-4 text-xs font-bold uppercase tracking-[0.18em] text-primary sm:block md:ml-0"
				>
					Dashboard
				</div>
				<Breadcrumb.Root>
					<Breadcrumb.List class="ml-12 md:ml-0">
						{#each paths as item, index (item)}
							{#if index !== paths.length - 1}
								<Breadcrumb.Item>
									<Breadcrumb.Link class="capitalize" href={getLink(item)}>
										{item.replace("-", " ")}
									</Breadcrumb.Link>
								</Breadcrumb.Item>
							{:else}
								<Breadcrumb.Item>
									<Breadcrumb.Page class="capitalize">
										{getBreadcrumbLabel(item, index)}
									</Breadcrumb.Page>
								</Breadcrumb.Item>
							{/if}
							{#if index < paths.length - 1}
								<Breadcrumb.Separator>/</Breadcrumb.Separator>
							{/if}
						{/each}
					</Breadcrumb.List>
				</Breadcrumb.Root>
			</div>
		</header>
		<div class="mx-auto w-full max-w-[90rem]">{@render children()}</div>
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
	overflow-x: hidden;
}

@media (min-width: 768px) {
	main {
		width: calc(100vw - var(--sidebar-width));
	}
}
</style>
