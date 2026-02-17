<script lang="ts">
	/* eslint-disable @typescript-eslint/no-explicit-any */
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import type { Database, Tables } from '$database';
	import { Badge } from '$lib/components/ui/badge';
	import { Button } from '$lib/components/ui/button';
	import {
		createSvelteTable,
		FlexRender,
		renderComponent,
		renderSnippet
	} from '$lib/components/ui/data-table/index.js';
	import { Input } from '$lib/components/ui/input';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import * as Pagination from '$lib/components/ui/pagination/index.js';
	import * as Select from '$lib/components/ui/select';
	import * as Table from '$lib/components/ui/table/index.js';
	import * as Checkbox from '$lib/components/ui/checkbox/index.js';
	import SortHeader from '$lib/components/ui/table/sort-header.svelte';
	import type { MutationPayload } from '$lib/types';
	import type { SupabaseClient } from '@supabase/supabase-js';
	import {
		createMutation,
		createQuery,
		keepPreviousData,
		useQueryClient
	} from '@tanstack/svelte-query';
	import {
		getCoreRowModel,
		getExpandedRowModel,
		getPaginationRowModel,
		getSortedRowModel,
		type PaginationState,
		type RowSelectionState,
		type SortingState,
		type TableOptions
	} from '@tanstack/table-core';
	import dayjs from 'dayjs';
	import { createRawSnippet } from 'svelte';
	import { Cross2 } from 'svelte-radix';
	import ActionButtons from './actions-buttons.svelte';
	import { toast } from 'svelte-sonner';
	import { Loader2, SendIcon } from 'lucide-svelte';
	import { resendInvitations } from './admin.remote';

	const columns =
		'id,current_position,full_name,email,phone_number,status,age,initial_registration_date,last_contacted,medical_conditions,admin_notes,social_media_consent,guardian_first_name,guardian_last_name,guardian_phone_number,insurance_form_submitted,last_status_change,search_text';

	let pageSizeOptions = [10, 25, 50, 100];

	const { supabase }: { supabase: SupabaseClient<Database> } = $props();

	function getBadgeVariant(status: string) {
		switch (status) {
			case 'invited':
				return 'default';
			case 'joined':
				return 'secondary';
			case 'declined':
				return 'destructive';
			default:
				return 'default';
		}
	}

	const currentPage = $derived(Number(page.url.searchParams.get('page')) || 0);
	const pageSize = $derived(Number(page.url.searchParams.get('pageSize')) || 10);
	const searchQuery = $derived(page.url.searchParams.get('q') || '');
	const rangeStart = $derived(currentPage * pageSize);
	const rangeEnd = $derived(rangeStart + pageSize - 1);
	const sortingState: SortingState = $derived.by(() => {
		const sortColumn = page.url.searchParams.get('sort');
		const sortDirection = page.url.searchParams.get('direction');
		if (!sortColumn) return [];
		return [
			{
				id: sortColumn,
				desc: sortDirection === 'desc'
			}
		];
	});

	async function getWaitlistQuery({
		searchQuery,
		sortingState,
		rangeStart,
		rangeEnd,
		signal
	}: {
		searchQuery: string;
		sortingState: SortingState;
		rangeStart: number;
		rangeEnd: number;
		signal: AbortSignal;
	}) {
		let query = supabase.from('waitlist_management_view').select(columns, { count: 'exact' });
		if (searchQuery.length > 0) {
			query = query.textSearch('search_text', `'${searchQuery}'`, {
				type: 'websearch'
			});
		}
		if (sortingState.length > 0) {
			query = query.order(sortingState[0].id, {
				ascending: !sortingState[0].desc
			});
		}
		query = query.neq('status', 'joined');
		const { data, count, error } = await query.range(rangeStart, rangeEnd).abortSignal(signal);
		if (error) {
			throw error;
		}
		return { data, count: count ?? 0 };
	}

	const waitlistQueryKey = $derived([
		'waitlist',
		{ rangeStart, rangeEnd, sortingState, searchQuery }
	]);
	const waitlistQuery = createQuery<Awaited<ReturnType<typeof getWaitlistQuery>>>(() => ({
		queryKey: waitlistQueryKey,
		placeholderData: keepPreviousData,
		queryFn: ({ signal, queryKey }) => {
			const params = queryKey[1] as {
				rangeStart: number;
				rangeEnd: number;
				sortingState: SortingState;
				searchQuery: string;
			};
			return getWaitlistQuery({ ...params, signal });
		}
	}));
	const queryClient = useQueryClient();
	const inviteMember = createMutation(() => ({
		mutationFn: async (waitlistIds: string[]) =>
			supabase.functions
				.invoke('bulk_invite_with_subscription', {
					body: waitlistIds,
					method: 'POST'
				})
				.then((r) => {
					if (r.error) {
						throw r.error;
					}
				}),
		onMutate: (waitlistIds) => {
			const oldData = queryClient.getQueryData(waitlistQueryKey);
			queryClient.setQueryData(
				waitlistQueryKey,
				(oldData: Awaited<(typeof waitlistQuery)['data']>) => ({
					...oldData,
					data: oldData?.data?.map((d) => ({
						...d,
						...(d.id && waitlistIds.includes(d.id) ? { status: 'invited' } : {})
					}))
				})
			);
			return { oldData };
		},
		onSuccess: () => {
			selectedState = {};
			toast.success('Invitations are being processed in the background.');
		},
		onError: (oldData) => {
			toast.error('Something has gone wrong inviting members.');
			queryClient.setQueryData(waitlistQueryKey, oldData);
		}
	}));

	const resendInvitationLink = createMutation(() => ({
		mutationFn: async (emails: string[]) => resendInvitations({ emails }),
		onMutate: (emails) => {
			const oldData = queryClient.getQueryData(waitlistQueryKey);
			queryClient.setQueryData(
				waitlistQueryKey,
				(oldData: Awaited<(typeof waitlistQuery)['data']>) => ({
					...oldData,
					data: oldData?.data?.map((d) => ({
						...d,
						...(d.email && emails.includes(d.email) ? { status: 'invited' } : {})
					}))
				})
			);
			return { oldData };
		},
		onSuccess: () => {
			toast.success('Invitation link resent.');
		},
		onError: (oldData) => {
			toast.error('Something has gone wrong inviting members.');
			queryClient.setQueryData(waitlistQueryKey, oldData);
		}
	}));

	const updateWaitlistEntry = createMutation<
		void,
		Error,
		MutationPayload<'waitlist'> & { email: string }
	>(() => ({
		mutationFn: async ({ email, ...rest }) => {
			const { error } = await supabase.from('waitlist').update(rest).eq('email', email);
			if (error) throw error;
		},
		onSuccess: () => {
			waitlistQuery.refetch();
		},
		onSettled: () => {
			waitlistQuery.refetch();
		}
	}));

	function onPaginationChange(newPagination: Partial<PaginationState>) {
		const paginationState: PaginationState = {
			pageIndex: currentPage,
			pageSize,
			...newPagination
		};
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const newParams = new URLSearchParams(page.url.searchParams);
		newParams.set('page', paginationState.pageIndex.toString());
		newParams.set('pageSize', paginationState.pageSize.toString());
		const url = `/dashboard/beginners-workshop?${newParams.toString()}`;
		goto(resolve(url as any));
	}

	function onSortingChange(newSorting: SortingState) {
		const [sortingState] = newSorting;
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const newParams = new URLSearchParams(page.url.searchParams);
		newParams.set('sort', sortingState.id);
		newParams.set('direction', sortingState.desc ? 'desc' : 'asc');
		const url = `/dashboard/beginners-workshop?${newParams.toString()}`;
		goto(resolve(url as any));
	}

	function onSearchChange(newSearch: string) {
		// eslint-disable-next-line svelte/prefer-svelte-reactivity
		const newParams = new URLSearchParams(page.url.searchParams);
		newParams.set('q', newSearch);
		const url = `/dashboard/beginners-workshop?${newParams.toString()}`;
		goto(resolve(url as any));
	}

	// State for expanded rows
	let expandedState = $state({});
	let selectedState = $state<RowSelectionState>({});
	let inviteCount = $derived(Object.values(selectedState).filter(Boolean).length);

	const tableOptions = $state<TableOptions<Tables<'waitlist_management_view'>>>({
		autoResetPageIndex: false,
		manualPagination: true,
		manualSorting: true,
		getExpandedRowModel: getExpandedRowModel(),
		state: {
			get expanded() {
				return expandedState;
			},
			get pagination() {
				return {
					pageIndex: currentPage,
					pageSize
				} as PaginationState;
			},
			get sorting() {
				return sortingState;
			}
		},
		onExpandedChange: (updater) => {
			if (typeof updater === 'function') {
				expandedState = updater(expandedState);
			} else {
				expandedState = updater;
			}
		},
		onRowSelectionChange: (updater) => {
			if (typeof updater === 'function') {
				selectedState = updater(selectedState);
			} else {
				selectedState = updater;
			}
		},
		columns: [
			{
				header: '',
				id: 'selection',
				cell: ({ row }) => {
					return renderComponent(Checkbox.Checkbox, {
						checked: row.getIsSelected(),
						onCheckedChange: (value: boolean | 'indeterminate') => row.toggleSelected(!!value),
						disabled: row.original.status === 'invited'
					});
				}
			},
			{
				header: 'Actions',
				cell: ({ row }) => {
					return renderComponent(ActionButtons, {
						adminNotes: row.original.admin_notes ?? 'N/A',
						isExpanded: row.getIsExpanded(),
						onToggleExpand: () => row.toggleExpanded(),
						inviteMember: () => {
							if (row.original.status !== 'invited') {
								inviteMember.mutate([row.original.id!]);
							} else {
								resendInvitationLink.mutate([row.original.email!]);
							}
						},
						onEdit(newValue) {
							updateWaitlistEntry.mutate({
								email: row.original.email!,
								admin_notes: newValue
							});
						}
					});
				}
			},
			{
				accessorKey: 'current_position',
				header: ({ column }) =>
					renderComponent(SortHeader, {
						onclick: () => column.toggleSorting(column.getIsSorted() === 'asc'),
						header: 'Position',
						class: 'p-2',
						sortDirection: column.getIsSorted()
					})
			},
			{
				accessorKey: 'full_name',
				header: 'Full Name',
				footer: ({ table }) => `Total ${table.getRowCount() ?? 0} people on the waitlist`,
				cell: ({ getValue }) => {
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () =>
								`<div class="w-[100px] md:w-[120px] whitespace-break-spaces break-words">${value()}</div>`
						})),
						getValue()
					);
				}
			},
			{
				accessorKey: 'email',
				header: 'Email',
				cell: ({ getValue }) => {
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () =>
								`<a href="mailto:${value()}" class="w-[150px] md:w-[200px] whitespace-break-spaces break-words">${value()}</a>`
						})),
						getValue()
					);
				}
			},
			{
				accessorKey: 'phone_number',
				header: 'Phone Number',
				cell: ({ getValue }) => {
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () => `<div class="w-[120px]">${value()}</div>`
						})),
						getValue()
					);
				}
			},
			{
				accessorKey: 'social_media_consent',
				header: 'Social  Consent',
				cell: ({ getValue }) => {
					return renderComponent(Badge, {
						variant:
							getValue() !== 'no'
								? getValue() === 'yes_recognizable'
									? 'default'
									: 'secondary'
								: 'destructive',
						class: 'h-8',
						children: createRawSnippet(() => ({
							render: () =>
								`<p class="first-letter:capitalize">${getValue().replace('_', ', ')}</p>`
						}))
					});
				}
			},
			{
				accessorKey: 'status',
				header: 'Status',
				cell: ({ getValue }) => {
					return renderComponent(Badge, {
						variant: getValue(),
						class: 'h-8',
						children: createRawSnippet(() => ({
							render: () => `<p class="capitalize">${getValue().replace('-', ' ')}</p>`
						}))
					});
				}
			},
			{
				accessorKey: 'age',
				header: ({ column }) =>
					renderComponent(SortHeader, {
						onclick: () => column.toggleSorting(column.getIsSorted() === 'asc'),
						header: 'Age',
						class: 'p-2',
						sortDirection: column.getIsSorted()
					}),
				cell: ({ getValue }) => {
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () => {
								return `<div class="w-[120px] ${value() < 18 ? 'text-red-800' : ''}">${value() < 18 ? value() + '(👶)' : value()}</div>`;
							}
						})),
						getValue()
					);
				}
			},
			{
				accessorKey: 'initial_registration_date',
				header: ({ column }) =>
					renderComponent(SortHeader, {
						onclick: () => column.toggleSorting(column.getIsSorted() === 'asc'),
						header: 'Initial Registration',
						class: 'p-2',
						sortDirection: column.getIsSorted()
					}),
				cell: ({ getValue }) => {
					return renderSnippet(
						createRawSnippet(() => ({
							render: () => `<div class="w-[120px]">${dayjs(getValue()).format('DD/MM/YYYY')}</div>`
						})),
						getValue()
					);
				}
			},
			{
				accessorKey: 'last_contacted',
				header: 'Last Contacted',
				cell: ({ getValue }) => {
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () => `<div class="w-[120px]">${value()}</div>`
						})),
						getValue() ?? 'N/A'
					);
				}
			}
		],
		get data() {
			return waitlistQuery?.data?.data ?? [];
		},
		onPaginationChange: (updater) => {
			if (typeof updater === 'function') {
				onPaginationChange(
					updater({
						pageIndex: currentPage,
						pageSize
					})
				);
			} else {
				onPaginationChange(updater);
			}
		},
		onSortingChange: (updater) => {
			if (typeof updater === 'function') {
				onSortingChange(updater(sortingState));
			} else {
				onSortingChange(updater);
			}
		},
		get rowCount() {
			return waitlistQuery?.data?.count ?? 0;
		},
		getRowId: (row) => row.id!,
		getCoreRowModel: getCoreRowModel(),
		getPaginationRowModel: getPaginationRowModel(),
		getSortedRowModel: getSortedRowModel()
	});
	const table = createSvelteTable(tableOptions);
</script>

<div
	class="flex flex-col md:flex-row w-full max-w-auto items-stretch md:items-center space-x-2 mb-2 p-2"
>
	<span class="flex flex-nowrap items-center gap-2">
		<Input
			value={searchQuery}
			onchange={(t: Event & { currentTarget: EventTarget & HTMLInputElement }) =>
				onSearchChange(t.currentTarget.value)}
			placeholder="Search for a person"
			class="w-full md:max-w-md"
		/>

		{#if searchQuery !== ''}
			<Button variant="ghost" type="button" onclick={() => onSearchChange('')}>
				<Cross2 />
			</Button>
		{/if}
		{#if waitlistQuery.isFetching}
			<LoaderCircle />
		{/if}
	</span>

	<Button
		class="md:ml-auto"
		disabled={inviteCount === 0 || inviteMember.isPending}
		onclick={() => inviteMember.mutate(Object.keys(selectedState))}
	>
		{#if inviteMember.isPending}
			<Loader2 class="mr-2 h-4 w-4 animate-spin" />
		{:else}
			<SendIcon class="mr-2 h-4 w-4" />
		{/if}
		Invite {inviteCount} members
	</Button>
</div>
<!-- Desktop Table View (hidden on mobile) -->
<div class="hidden md:block overflow-x-auto overflow-y-auto h-[65svh]">
	<Table.Root class="w-full">
		<Table.Header class="sticky top-0 z-10 bg-white">
			{#each table.getHeaderGroups() as headerGroup (headerGroup.id)}
				<Table.Row>
					{#each headerGroup.headers as header (header.id)}
						<Table.Head class="text-black prose prose-p text-xs md:text-sm font-medium p-2">
							<FlexRender content={header.column.columnDef.header} context={header.getContext()} />
						</Table.Head>
					{/each}
				</Table.Row>
			{/each}
		</Table.Header>
		<Table.Body>
			{#each table.getRowModel().rows as row (row.id)}
				<Table.Row>
					{#each row.getVisibleCells() as cell (cell.id)}
						<Table.Cell
							class="whitespace-normal md:whitespace-nowrap py-2 md:py-4 px-2 md:px-3 text-xs md:text-sm prose prose-p"
						>
							<FlexRender content={cell.column.columnDef.cell} context={cell.getContext()} />
						</Table.Cell>
					{/each}
				</Table.Row>
				{#if row.getIsExpanded()}
					<Table.Row>
						<Table.Cell colspan={row.getVisibleCells().length} class="p-4 bg-muted/20">
							<div class="grid grid-cols-1 md:grid-cols-2 gap-4">
								<!-- Guardian Information -->
								<div class="bg-card rounded-lg border p-4">
									<h3 class="text-sm font-medium mb-2">Guardian Information</h3>
									{#if row.original.guardian_first_name || row.original.guardian_last_name || row.original.guardian_phone_number}
										<div class="grid grid-cols-3 gap-2">
											<div class="text-xs font-medium text-muted-foreground">Name</div>
											<div class="col-span-2 text-xs">
												{row.original.guardian_first_name || ''}
												{row.original.guardian_last_name || ''}
											</div>

											<div class="text-xs font-medium text-muted-foreground">Phone</div>
											<div class="col-span-2 text-xs">
												{row.original.guardian_phone_number || 'N/A'}
											</div>
										</div>
									{:else}
										<p class="text-xs text-muted-foreground">No guardian information available</p>
									{/if}
								</div>

								<!-- Medical Conditions -->
								<div class="bg-card rounded-lg border p-4">
									<h3 class="text-sm font-medium mb-2">Medical Conditions</h3>
									<p class="text-xs">
										{row.original.medical_conditions || 'None reported'}
									</p>
								</div>
							</div>
						</Table.Cell>
					</Table.Row>
				{/if}
			{/each}
		</Table.Body>
		<Table.Footer class="sticky bottom-0 z-1 bg-white">
			{#each table.getFooterGroups() as footerGroup (footerGroup.id)}
				<Table.Row>
					{#each footerGroup.headers as header (header.id)}
						<Table.Cell>
							{#if !header.isPlaceholder}
								<FlexRender
									content={header.column.columnDef.footer}
									context={header.getContext()}
								/>
							{/if}
						</Table.Cell>
					{/each}
				</Table.Row>
			{/each}
		</Table.Footer>
	</Table.Root>
</div>

<!-- Mobile Card View (hidden on desktop) -->
<div class="md:hidden overflow-y-auto h-[60svh] px-2 py-1">
	<div class="space-y-4">
		{#if table.getRowCount() === 0}
			<p class="text-foreground">No results found</p>
		{/if}
		{#each table.getRowModel().rows as row (row.id)}
			<div class="bg-card text-card-foreground rounded-lg border shadow-sm p-4">
				<!-- Name and Actions Row -->
				<div class="flex justify-between items-center mb-3">
					<div class="font-medium text-base">
						{row.original.full_name}
						<!-- Position Badge -->
						<span class="ml-2 text-xs bg-muted text-muted-foreground rounded-full px-2 py-1">
							#{row.original.current_position}
						</span>
					</div>
					<!-- Actions -->
					<div>
						<ActionButtons
							inviteMember={() => {
								if (row.original.status !== 'invited') {
									inviteMember.mutate([row.original.id!]);
								} else {
									resendInvitationLink.mutate([row.original.email!]);
								}
							}}
							adminNotes={row.original.admin_notes ?? 'N/A'}
							isExpanded={row.getIsExpanded()}
							onToggleExpand={() => row.toggleExpanded()}
							onEdit={(newValue) => {
								if (row.original.email) {
									updateWaitlistEntry.mutate({
										email: row.original.email,
										admin_notes: newValue
									});
								}
							}}
						/>
					</div>
				</div>

				<!-- Status Badge -->
				<div class="mb-3">
					{#if row.original.status}
						<Badge variant={getBadgeVariant(row.original.status)} class="h-8">
							<p class="capitalize">{row.original.status.replace('-', ' ')}</p>
						</Badge>
					{:else}
						<Badge variant="default" class="h-8">
							<p>Unknown</p>
						</Badge>
					{/if}
				</div>

				<!-- Email -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Email</div>
					<div class="col-span-2 text-sm break-words">
						<a href="mailto:{row.original.email}">{row.original.email}</a>
					</div>
				</div>

				<!-- Phone -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Phone</div>
					<div class="col-span-2 text-sm">{row.original.phone_number || 'N/A'}</div>
				</div>

				<!-- Age -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Age</div>
					<div class="col-span-2 text-sm">{row.original.age || 'N/A'}</div>
				</div>

				<!-- Registration Date -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Registered</div>
					<div class="col-span-2 text-sm">
						{#if row.original.initial_registration_date}
							{dayjs(row.original.initial_registration_date).format('MMM D, YYYY')}
						{:else}
							N/A
						{/if}
					</div>
				</div>

				<!-- Last Contacted -->
				<div class="grid grid-cols-3 py-1">
					<div class="text-sm font-medium text-muted-foreground">Last Contact</div>
					<div class="col-span-2 text-sm">
						{#if row.original.last_contacted}
							{dayjs(row.original.last_contacted).format('MMM D, YYYY')}
						{:else}
							Never
						{/if}
					</div>
				</div>

				<!-- Expanded Content -->
				{#if row.getIsExpanded()}
					<div class="mt-4 pt-4 border-t border-muted">
						<!-- Guardian Information -->
						<div class="mb-4">
							<h3 class="text-sm font-medium mb-2">Guardian Information</h3>
							{#if row.original.guardian_first_name || row.original.guardian_last_name || row.original.guardian_phone_number}
								<div class="grid grid-cols-3 gap-2">
									<div class="text-xs font-medium text-muted-foreground">Name</div>
									<div class="col-span-2 text-xs">
										{row.original.guardian_first_name || ''}
										{row.original.guardian_last_name || ''}
									</div>

									<div class="text-xs font-medium text-muted-foreground">Phone</div>
									<div class="col-span-2 text-xs">
										{row.original.guardian_phone_number || 'N/A'}
									</div>
								</div>
							{:else}
								<p class="text-xs text-muted-foreground">No guardian information available</p>
							{/if}
						</div>

						<!-- Medical Conditions -->
						<div>
							<h3 class="text-sm font-medium mb-2">Medical Conditions</h3>
							<p class="text-xs">
								{row.original.medical_conditions || 'None reported'}
							</p>
						</div>
					</div>
				{/if}
			</div>
		{/each}
	</div>
</div>
<div class="flex flex-col md:flex-row items-center justify-between gap-4 p-4 bg-card border-t">
	<div class="flex items-center gap-2 w-full md:w-auto justify-start">
		<p class="text-sm text-muted-foreground">Elements per page</p>
		<Select.Root
			type="single"
			value={pageSize.toString()}
			onValueChange={(value) => onPaginationChange({ pageSize: Number(value) })}
		>
			<Select.Trigger class="w-16 h-8">{pageSize}</Select.Trigger>
			<Select.Content>
				{#each pageSizeOptions as pageSizeOption (pageSizeOption)}
					<Select.Item value={pageSizeOption.toString()}>
						{pageSizeOption}
					</Select.Item>
				{/each}
			</Select.Content>
		</Select.Root>
	</div>
	<div class="w-full md:w-auto flex justify-center md:justify-end">
		<Pagination.Root
			count={waitlistQuery?.data?.count ?? 0}
			perPage={pageSize}
			page={currentPage + 1}
			onPageChange={(page) => table.setPageIndex(page - 1)}
			class="m-0"
		>
			{#snippet children({ pages, currentPage })}
				<Pagination.Content>
					<Pagination.Item>
						<Pagination.PrevButton />
					</Pagination.Item>
					{#each pages as page (page.key)}
						{#if page.type === 'ellipsis'}
							<Pagination.Item class="hidden sm:block">
								<Pagination.Ellipsis />
							</Pagination.Item>
						{:else}
							<Pagination.Item
								class={page.value !== currentPage &&
								page.value !== currentPage - 1 &&
								page.value !== currentPage + 1
									? 'hidden sm:block'
									: ''}
							>
								<Pagination.Link {page} isActive={currentPage === page.value}>
									{page.value}
								</Pagination.Link>
							</Pagination.Item>
						{/if}
					{/each}
					<Pagination.Item>
						<Pagination.NextButton />
					</Pagination.Item>
				</Pagination.Content>
			{/snippet}
		</Pagination.Root>
	</div>
</div>
