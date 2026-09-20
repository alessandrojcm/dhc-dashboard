<script lang="ts">
import type { LayoutData } from "./$types";
import { SidebarProvider } from "$lib/components/ui/sidebar";
import DashboardSidebar from "$lib/components/ui/DashboardSidebar.svelte";
import { page } from "$app/state";
import * as Breadcrumb from "$lib/components/ui/breadcrumb";
import { createMutation, createQuery } from "@tanstack/svelte-query";
import { goto } from "$app/navigation";
import { invalidateAll, invalidate } from "$app/navigation";
import { resolve } from "$app/paths";
import {
	inventoryCategoriesIndexOptions,
	membersMeOptions,
	authSessionDeleteSession,
	notificationsPushUnsubscribeMutation,
} from "@dhc/api-client";
import { browserPushManager } from "$lib/notifications/web-push/browser";
import { forgetPushSubscription } from "$lib/notifications/web-push/workflow";
import type { Snippet } from "svelte";

let { children, data }: { data: LayoutData; children: Snippet } = $props();
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
const CATEGORY_DETAIL_ROUTE = "/dashboard/inventory/categories/[[categoryId]]";
const ITEM_DETAIL_ROUTE = "/dashboard/inventory/items/[[itemId]]";
const breadcrumbCategoriesQuery = createQuery(() => ({
	...inventoryCategoriesIndexOptions(),
	enabled:
		page.route.id === CATEGORY_DETAIL_ROUTE && Boolean(page.params.categoryId),
	select: (response) => response.data.categories,
}));

/**
 * ALE-164: sign out via `DELETE /api/auth/session` (Phoenix revokes the
 * session token and clears the `_dhc_session` cookie). The generated
 * client sends the cookie with `credentials: 'include'`; no Supabase
 * `auth.signOut()` call remains.
 */
const unsubscribePush = createMutation(() =>
	notificationsPushUnsubscribeMutation(),
);

async function logout() {
	// ALE-299: drop this browser's Web Push subscription first, while the
	// session cookie can still authorise removing the server row. Otherwise a
	// shared device keeps receiving the departing member's notifications until
	// the next member opens the notification centre. Best-effort.
	try {
		await forgetPushSubscription({
			browser: await browserPushManager(),
			server: {
				unregister: async (endpoint) => {
					await unsubscribePush.mutateAsync({ body: { endpoint } });
					return true;
				},
			},
		});
	} catch {
		// Never block sign-out on push cleanup.
	}
	try {
		await authSessionDeleteSession();
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

// Routes whose breadcrumb shows a workshop id segment. Their loads already
// fetch the workshop, so `page.data` (merged across all loads) carries the
// title — swap the raw id for it, falling back to a generic label.
const WORKSHOP_ID_ROUTES = new Set([
	"/dashboard/workshops/[id]/edit",
	"/dashboard/workshops/[id]/attendees",
]);

function getBreadcrumbLabel(item: string, index: number): string {
	const isMemberProfile =
		page.route.id === "/dashboard/members/[memberId]" &&
		index === paths.length - 1;
	if (isMemberProfile) {
		return userDataQuery.data?.id === page.params.memberId
			? "My profile"
			: "Member profile";
	}
	if (item === page.params.id && WORKSHOP_ID_ROUTES.has(page.route.id ?? "")) {
		// SAFETY: the attendees load returns Phoenix's WorkshopAttendeesResponse
		// envelope verbatim (`{ data: { workshop } }`); only `title` is read.
		const attendeesEnvelope = page.data.attendeesResponse as
			| { data?: { workshop?: { title?: string } } }
			| undefined;
		const workshop = page.data.workshop ?? attendeesEnvelope?.data?.workshop;
		return workshop?.title || "Workshop";
	}
	if (
		page.route.id === CATEGORY_DETAIL_ROUTE &&
		item === page.params.categoryId
	) {
		return (
			breadcrumbCategoriesQuery.data?.find(
				(category) => category.id === page.params.categoryId,
			)?.name ?? "Category"
		);
	}
	if (page.route.id === ITEM_DETAIL_ROUTE && item === page.params.itemId) {
		return item === "new" ? "Add item" : item;
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
					class="ml-14 hidden border-r border-border pr-4 text-xs font-bold uppercase tracking-[0.18em] text-primary sm:block md:ml-0"
				>
					Dashboard
				</div>
				<Breadcrumb.Root>
					<Breadcrumb.List class="ml-14 md:ml-0">
						{#each paths as item, index (item)}
							{#if index !== paths.length - 1}
								<Breadcrumb.Item>
									<Breadcrumb.Link class="capitalize" href={getLink(item)}>
										{getBreadcrumbLabel(item, index)}
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
