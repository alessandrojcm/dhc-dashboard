<script lang="ts">
	import { onMount } from 'svelte';
	import dayjs from 'dayjs';
	import relativeTime from 'dayjs/plugin/relativeTime';
	import type { SupabaseClient } from '@supabase/supabase-js';
	import { createInfiniteQuery, createMutation, useQueryClient } from '@tanstack/svelte-query';
	import type { Database } from '$database';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
	import { Bell } from 'lucide-svelte';

	// Initialize dayjs plugins
	dayjs.extend(relativeTime);

	const {
		supabase
	}: {
		supabase: SupabaseClient<Database>;
	} = $props();

	type Notification = Database['public']['Tables']['notifications']['Row'];

	// Pagination parameters
	const PAGE_SIZE = 10;

	// Create infinite query for notifications
	const notificationsQuery = createInfiniteQuery(() => ({
		queryKey: ['notifications'],
		initialData: {
			pages: [],
			pageParams: []
		},
		queryFn: async ({ pageParam = 0, signal }) => {
			// Get total count for unread notifications
			const { count, error: countError } = await supabase
				.from('notifications')
				.select('*', { count: 'exact', head: true })
				.is('read_at', null)
				.abortSignal(signal);

			if (countError) throw countError;

			// Fetch paginated notifications
			const { data, error } = await supabase
				.from('notifications')
				.select('*')
				.order('created_at', { ascending: false })
				.range(pageParam, pageParam + PAGE_SIZE - 1)
				.abortSignal(signal);

			if (error) throw error;

			// Determine if there are more pages
			const nextCursor = data && data.length === PAGE_SIZE ? pageParam + PAGE_SIZE : null;

			return {
				data: data || [],
				nextCursor,
				count: count || 0
			};
		},
		getNextPageParam: (lastPage) => lastPage.nextCursor,
		initialPageParam: 0
	}));

	const markAsRead = createMutation(() => ({
		mutationFn: async (notificationId: string) => {
			const { error } = await supabase.rpc('mark_notification_as_read', {
				notification_id: notificationId
			});

			if (error) throw error;
		},
		onMutate: async (notificationId) => {
			const previousData = queryClient.getQueryData<Notification[]>(['notifications']);
			queryClient.setQueryData(
				['notifications'],
				(oldData: (typeof notificationsQuery)['data']) => {
					// Find if the notification being marked as read is currently unread
					const targetNotification = oldData?.pages
						.flatMap((page) => page.data)
						.find((notification) => notification.id === notificationId);

					// Only decrease count if the notification was previously unread
					const shouldDecreaseCount = targetNotification && !targetNotification.read_at;

					// Calculate new count if needed
					const newCount =
						shouldDecreaseCount && oldData?.pages[0]?.count !== undefined
							? Math.max(0, oldData.pages[0].count - 1) // Ensure count doesn't go below 0
							: oldData?.pages[0]?.count;

					return {
						...oldData,
						pages: oldData?.pages.map((page, index) => ({
							...page,
							// Update count in the first page
							...(index === 0 && newCount !== undefined ? { count: newCount } : {}),
							data: page.data
								.map((notification) =>
									notification.id === notificationId
										? { ...notification, read_at: new Date().toISOString() }
										: notification
								)
								.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
						}))
					};
				}
			);
			return { previousData };
		},
		onError: async (_, __, context) => {
			await queryClient.setQueryData(['notifications'], context?.previousData);
		}
	}));

	const markAllAsRead = createMutation(() => ({
		mutationFn: async () => {
			return supabase
				.from('notifications')
				.update({ read_at: new Date().toISOString() })
				.eq('user_id', (await supabase.auth.getUser())?.data.user!.id)
				.throwOnError();
		},
		onMutate: async () => {
			const previousData = queryClient.getQueryData<Notification[]>(['notifications']);
			queryClient.setQueryData(
				['notifications'],
				(oldData: (typeof notificationsQuery)['data']) => ({
					...oldData,
					pages: oldData?.pages.map((page, index) => ({
						...page,
						// Set count to 0 in the first page since all notifications will be read
						...(index === 0 ? { count: 0 } : {}),
						data: page.data
							.map((notification) => ({
								...notification,
								read_at: new Date().toISOString()
							}))
							.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
					}))
				})
			);
			return { previousData };
		},
		onError: async (_, __, context) => {
			await queryClient.setQueryData(['notifications'], context?.previousData);
		}
	}));

	const queryClient = useQueryClient();

	onMount(() => {
		const subscription = supabase
			.channel('notifications')
			.on(
				'postgres_changes',
				{
					event: 'INSERT',
					schema: 'public',
					table: 'notifications'
				},
				(payload: { new: Notification }) => {
					queryClient.setQueryData(
						['notifications'],
						(oldData: (typeof notificationsQuery)['data']) => {
							// Increase the count for unread notifications if this is a new unread notification
							const newCount =
								!payload.new.read_at && oldData?.pages[0]?.count !== undefined
									? oldData.pages[0].count + 1
									: oldData?.pages[0]?.count;

							return {
								...oldData,
								pages: oldData?.pages.map((page, index) => ({
									...page,
									// Update count in the first page
									...(index === 0 && newCount !== undefined ? { count: newCount } : {}),
									data: page.data
										.concat(payload.new)
										.sort(
											(a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
										)
								}))
							};
						}
					);
				}
			)
			.on(
				'postgres_changes',
				{
					event: 'UPDATE',
					schema: 'public',
					table: 'notifications'
				},
				(payload: { new: Notification }) => {
					queryClient.setQueryData(
						['notifications'],
						(oldData: (typeof notificationsQuery)['data']) => ({
							...oldData,
							pages: oldData?.pages.map((page) => ({
								...page,
								data: page.data.map((notification) =>
									notification.id === payload.new.id ? payload.new : notification
								)
							}))
						})
					);
				}
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
			const diffInHours = now.diff(date, 'hour');

			if (diffInHours < 24) {
				return date.fromNow();
			} else {
				return date.format('MMM D, YYYY');
			}
		} catch (e) {
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
