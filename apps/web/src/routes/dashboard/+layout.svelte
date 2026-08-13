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
let paths = $derived.by(() => page.url.pathname.split("/").filter(Boolean));
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
<a class="skip-link" href="#dashboard-content">Skip to main content</a>
<SidebarProvider class="min-h-dvh bg-transparent">
	<DashboardSidebar
		{roles}
		{logout}
		userData={userDataQuery.promise}
		navData={data.navData}
	/>
	<main id="dashboard-content" class="w-full" tabindex="-1">
		<header class="dashboard-header">
			<div>
				<p class="eyebrow">Dublin Hema Club</p>
				<h1>Club operations</h1>
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
									{item.replaceAll("-", " ")}
								</Breadcrumb.Page>
							</Breadcrumb.Item>
						{/if}
						{#if index < paths.length - 1}
							<Breadcrumb.Separator>/</Breadcrumb.Separator>
						{/if}
					{/each}
				</Breadcrumb.List>
			</Breadcrumb.Root>
		</header>
		<Separator />
		<div class="dashboard-content">
			{@render children()}
		</div>
	</main>
</SidebarProvider>

<style>
.skip-link {
	position: fixed;
	top: 0.75rem;
	left: 0.75rem;
	z-index: 100;
	transform: translateY(-160%);
	border-radius: 0.375rem;
	background: hsl(var(--secondary));
	padding: 0.75rem 1rem;
	color: hsl(var(--secondary-foreground));
	font-weight: 700;
	transition: transform 150ms ease-out;
}

.skip-link:focus {
	transform: translateY(0);
}

main {
	flex: 1;
	display: flex;
	flex-direction: column;
	width: 100%;
	margin: 0 auto;
	box-sizing: border-box;
	background: hsl(var(--background) / 0.72);
}

.dashboard-header {
	display: flex;
	align-items: flex-end;
	justify-content: space-between;
	gap: 1rem;
	padding: 1.25rem 1.5rem;
}

.eyebrow {
	margin: 0 0 0.25rem;
	color: hsl(var(--secondary));
	font-size: 0.6875rem;
	font-weight: 800;
	letter-spacing: 0.16em;
	text-transform: uppercase;
}

h1 {
	margin: 0;
	color: hsl(var(--foreground));
	font-family: Georgia, "Times New Roman", serif;
	font-size: clamp(1.5rem, 2vw, 2rem);
	font-weight: 700;
	letter-spacing: -0.035em;
	line-height: 1;
}

.dashboard-content {
	padding: 1.5rem;
}

@media (min-width: 768px) {
	main {
		width: calc(100vw - var(--sidebar-width));
	}

	.dashboard-header,
	.dashboard-content {
		padding-left: 2rem;
		padding-right: 2rem;
	}
}

@media (max-width: 640px) {
	.dashboard-header {
		align-items: flex-start;
		flex-direction: column;
		padding-top: 4.5rem;
	}

	.dashboard-content {
		padding: 1rem;
	}
}
</style>
