<script lang="ts">
import { onMount } from "svelte";
import {
	notificationsListInfiniteOptions,
	notificationsListInfiniteQueryKey,
	type Notification as ApiNotification,
} from "@dhc/api-client";
import dayjs from "dayjs";
import relativeTime from "dayjs/plugin/relativeTime";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
	createInfiniteQuery,
	createMutation,
	useQueryClient,
} from "@tanstack/svelte-query";
import type { Database } from "$database";
import * as DropdownMenu from "$lib/components/ui/dropdown-menu/index.js";
import { Bell } from "lucide-svelte";

// Initialize dayjs plugins
dayjs.extend(relativeTime);

const {
	supabase,
}: {
	supabase: SupabaseClient<Database>;
} = $props();

type Notification = Database["public"]["Tables"]["notifications"]["Row"];

type NotificationsPage = {
	data: Notification[];
	nextCursor: string | null;
	count: number;
};

type NotificationsInfiniteData = {
	pages: NotificationsPage[];
	pageParams: (string | null)[];
};

// Pagination parameters
const PAGE_SIZE = 10 as const;
const notificationsOptions = { query: { limit: PAGE_SIZE } };
const notificationsQueryKey =
	notificationsListInfiniteQueryKey(notificationsOptions);

// Create infinite query for notifications
const notificationsQuery = createInfiniteQuery(() => ({
	...notificationsListInfiniteOptions(notificationsOptions),
	initialPageParam: { query: {} },
	getNextPageParam: (lastPage) => lastPage.data.nextCursor ?? undefined,
	select: (data): NotificationsInfiniteData => ({
		...data,
		pages: data.pages.map((response) => ({
			data: response.data.notifications.map(toNotificationRow),
			nextCursor: response.data.nextCursor,
			count: response.data.unreadCount,
		})),
		pageParams: data.pageParams.map((pageParam) =>
			typeof pageParam === "string" ? pageParam : null,
		),
	}),
}));

function toNotificationRow(notification: ApiNotification): Notification {
	return {
		id: notification.id,
		body: notification.body,
		created_at: notification.createdAt,
		read_at: notification.readAt,
		user_id: "",
	};
}

const markAsRead = createMutation(() => ({
	mutationFn: async (notificationId: string) => {
		const { error } = await supabase.rpc("mark_notification_as_read", {
			notification_id: notificationId,
		});

		if (error) throw error;
	},
	onSuccess: () => {
		queryClient.invalidateQueries({ queryKey: notificationsQueryKey });
	},
}));

const markAllAsRead = createMutation(() => ({
	mutationFn: async () => {
		return supabase
			.from("notifications")
			.update({ read_at: new Date().toISOString() })
			.eq("user_id", (await supabase.auth.getUser())?.data.user!.id)
			.throwOnError();
	},
	onSuccess: () => {
		queryClient.invalidateQueries({ queryKey: notificationsQueryKey });
	},
}));

const queryClient = useQueryClient();

onMount(() => {
	const subscription = supabase
		.channel("notifications")
		.on(
			"postgres_changes",
			{
				event: "INSERT",
				schema: "public",
				table: "notifications",
			},
			() => {
				queryClient.invalidateQueries({ queryKey: notificationsQueryKey });
			},
		)
		.on(
			"postgres_changes",
			{
				event: "UPDATE",
				schema: "public",
				table: "notifications",
			},
			() => {
				queryClient.invalidateQueries({ queryKey: notificationsQueryKey });
			},
		)
		.subscribe();

	return () => {
		try {
			subscription.unsubscribe();
		} catch (e) {
			console.warn(e);
		}
	};
});

function formatTime(timestamp: string): string {
	try {
		const date = dayjs(timestamp);
		const now = dayjs();
		const diffInHours = now.diff(date, "hour");

		if (diffInHours < 24) {
			return date.fromNow();
		} else {
			return date.format("MMM D, YYYY");
		}
	} catch {
		return timestamp;
	}
}
</script>

<DropdownMenu.Root>
	<DropdownMenu.Trigger
		class="relative flex items-center py-2 rounded hover:bg-muted min-h-[40px] w-full"
	>
		<div class="flex items-center w-full px-5">
			<Bell
				size={20}
				class="mr-2 {notificationsQuery?.data?.pages?.[0]?.count &&
				notificationsQuery.data.pages[0].count > 0
					? 'text-primary animate-pulse'
					: ''}"
			/>
			<span
				class={notificationsQuery?.data?.pages?.[0]?.count &&
				notificationsQuery.data.pages[0].count > 0
					? 'font-medium'
					: ''}>Notifications</span
			>
			{#if notificationsQuery?.data?.pages?.[0]?.count && notificationsQuery.data.pages[0].count > 0}
				<span
					class="absolute -top-1 right-2 flex items-center justify-center w-5 h-5 text-[10px] font-semibold bg-red-500 text-white rounded-full"
				>
					{notificationsQuery.data.pages[0].count}
				</span>
			{/if}
		</div>
	</DropdownMenu.Trigger>

	<DropdownMenu.Content class="w-[380px] max-h-[500px] overflow-hidden p-0">
		<DropdownMenu.Group>
			<div class="flex justify-between items-center px-4 py-3">
				<DropdownMenu.GroupHeading>Notifications</DropdownMenu.GroupHeading>
				{#if notificationsQuery?.data?.pages?.[0]?.data?.some((n) => !n.read_at)}
					<button
						class="text-xs text-primary bg-transparent border-none cursor-pointer"
						onclick={() => markAllAsRead.mutate()}
					>
						Mark all as read
					</button>
				{/if}
			</div>

			<DropdownMenu.Separator />

			<div class="max-h-[400px] overflow-y-auto">
				{#if notificationsQuery.isLoading}
					<div class="py-6 px-4 text-center text-muted-foreground text-sm">
						Loading notifications...
					</div>
				{:else if notificationsQuery.isError}
					<div class="py-6 px-4 text-center text-red-500 text-sm">Error loading notifications</div>
				{:else if !notificationsQuery.data?.pages?.[0]?.data?.length}
					<div class="py-6 px-4 text-center text-muted-foreground text-sm">No notifications</div>
				{:else}
					{#each notificationsQuery.data.pages.flatMap((page) => page.data) as notification (notification.id)}
						<div
							class="flex items-center gap-3 px-4 py-3 border-b border-border hover:bg-muted transition-colors"
						>
							{#if !notification.read_at}
								<div class="w-2 h-2 rounded-full bg-red-500 flex-shrink-0"></div>
							{:else}
								<div class="w-2 h-2 flex-shrink-0"></div>
							{/if}
							<div class="flex-1 min-w-0">
								<p class="m-0 text-sm leading-normal">{notification.body}</p>
								<span class="text-xs text-muted-foreground block"
									>{formatTime(notification.created_at)}</span
								>
							</div>
							{#if !notification.read_at}
								<button
									class="p-1 rounded-full text-primary hover:bg-primary-foreground flex-shrink-0 flex items-center justify-center"
									onclick={() => markAsRead.mutate(notification.id)}
								>
									<span class="sr-only">Mark as read</span>
									<svg
										xmlns="http://www.w3.org/2000/svg"
										width="16"
										height="16"
										viewBox="0 0 24 24"
										fill="none"
										stroke="currentColor"
										stroke-width="2"
										stroke-linecap="round"
										stroke-linejoin="round"
									>
										<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"></path>
										<circle cx="12" cy="12" r="3"></circle>
									</svg>
								</button>
							{/if}
						</div>
					{/each}

					{#if notificationsQuery.hasNextPage}
						<button
							class="w-full py-3 text-center bg-transparent border-none border-t border-border text-primary text-sm cursor-pointer hover:bg-muted disabled:text-muted-foreground disabled:cursor-not-allowed"
							onclick={() => notificationsQuery.fetchNextPage()}
							disabled={notificationsQuery.isFetchingNextPage}
						>
							{notificationsQuery.isFetchingNextPage ? 'Loading more...' : 'Load more'}
						</button>
					{/if}
				{/if}
			</div>
		</DropdownMenu.Group>
	</DropdownMenu.Content>
</DropdownMenu.Root>

<style>
	.sr-only {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		margin: -1px;
		overflow: hidden;
		clip: rect(0, 0, 0, 0);
		white-space: nowrap;
		border-width: 0;
	}
</style>
