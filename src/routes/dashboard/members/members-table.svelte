<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/stores';
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
	import * as Sheet from '$lib/components/ui/sheet';
	import * as Table from '$lib/components/ui/table/index.js';
	import SortHeader from '$lib/components/ui/table/sort-header.svelte';
	import type { SupabaseClient } from '@supabase/supabase-js';
	import { Edit } from 'lucide-svelte';
	import { createQuery, keepPreviousData } from '@tanstack/svelte-query';
	import {
		getCoreRowModel,
		getPaginationRowModel,
		getSortedRowModel,
		type PaginationState,
		type SortingState,
		type TableOptions
	} from '@tanstack/table-core';
	import dayjs from 'dayjs';
	import { Ambulance } from 'lucide-svelte';
	import { createRawSnippet } from 'svelte';
	import { Cross2 } from 'svelte-radix';
	import MemberActions from './member-actions.svelte';

	const columns =
		'id,first_name,last_name,email,phone_number,gender,pronouns,is_active,preferred_weapon,membership_start_date,membership_end_date,last_payment_date,insurance_form_submitted,roles,age,social_media_consent';

	let pageSizeOptions = [10, 25, 50, 100];

	const { supabase }: { supabase: SupabaseClient<Database> } = $props();

	const currentPage = $derived(Number($page.url.searchParams.get('page')) || 0);
	const pageSize = $derived(Number($page.url.searchParams.get('pageSize')) || 10);
	const searchQuery = $derived($page.url.searchParams.get('q') || '');
	const rangeStart = $derived(currentPage * pageSize);
	const rangeEnd = $derived(rangeStart + pageSize);
	const sortingState: SortingState = $derived.by(() => {
		const sortColumn = $page.url.searchParams.get('sort');
		const sortDirection = $page.url.searchParams.get('direction');
		if (!sortColumn) return [];
		return [
			{
				id: sortColumn,
				desc: sortDirection === 'desc'
			}
		];
	});
	let selectedMemberId = $state<string | null>(null);
	const selectedMemberQuery = createQuery(() => ({
		queryKey: ['selectedMemberId', selectedMemberId],
		enabled: selectedMemberId !== null,
		queryFn: async ({ signal }) => {
			return await supabase
				.rpc('get_member_data', {
					user_uuid: selectedMemberId!
				})
				.abortSignal(signal)
				.single()
				.throwOnError()
				.then((r) => r.data);
		}
	}));

	const membersQuery = createQuery(() => ({
		queryKey: ['members', pageSize, currentPage, rangeStart, sortingState, searchQuery],
		placeholderData: keepPreviousData,
		initialData: { data: [], count: 0 },
		queryFn: async ({ signal }) => {
			let query = supabase.from('member_management_view').select(columns, { count: 'estimated' });
			if (searchQuery.length > 0) {
				query = query.textSearch('search_text', `'${searchQuery}'`, {
					type: 'websearch'
				});
			}
			if (sortingState.length > 0) {
				query = query.order(sortingState[0].id, { ascending: !sortingState[0].desc });
			}
			const { data, error } = await query
				.range(rangeStart, rangeEnd)
				.abortSignal(signal)
				.throwOnError();
			if (error) {
				throw error;
			}
			return { data, count: data.length };
		}
	}));

	function onPaginationChange(newPagination: Partial<PaginationState>) {
		const paginationState: PaginationState = {
			pageIndex: currentPage,
			pageSize,
			...newPagination
		};
		const newParams = new URLSearchParams($page.url.searchParams);
		newParams.set('page', paginationState.pageIndex.toString());
		newParams.set('pageSize', paginationState.pageSize.toString());
		goto(`/dashboard/members?${newParams.toString()}`);
	}

	function onSortingChange(newSorting: SortingState) {
		const [sortingState] = newSorting;
		const newParams = new URLSearchParams($page.url.searchParams);
		newParams.set('sort', sortingState.id);
		newParams.set('direction', sortingState.desc ? 'desc' : 'asc');
		goto(`/dashboard/members?${newParams.toString()}`);
	}

	function onSearchChange(newSearch: string) {
		const newParams = new URLSearchParams($page.url.searchParams);
		newParams.set('q', newSearch);
		goto(`/dashboard/members?${newParams.toString()}`);
	}

	const tableOptions = $state<TableOptions<Tables<'member_management_view'>>>({
		autoResetPageIndex: false,
		manualPagination: true,
		manualSorting: true,
		columns: [
			{
				id: 'actions',
				header: 'Actions',
				cell: ({ row }) => {
					return renderComponent(MemberActions, {
						memberId: row.original.id!,
						userId: row.original.id!,
						setSelectedUserId: (id: string) => (selectedMemberId = id)
					});
				}
			},
			{
				accessorKey: 'first_name',
				header: ({ column }) =>
					renderComponent(SortHeader, {
						onclick: () => column.toggleSorting(column.getIsSorted() === 'asc'),
						header: 'First Name',
						class: 'p-2',
						sortDirection: column.getIsSorted()
					}),
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
				accessorKey: 'last_name',
				header: ({ column }) =>
					renderComponent(SortHeader, {
						onclick: () => column.toggleSorting(column.getIsSorted() === 'asc'),
						header: 'Last Name',
						class: 'p-2',
						sortDirection: column.getIsSorted()
					}),
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
				accessorKey: 'is_active',
				header: 'Status',
				cell: ({ getValue }) => {
					return renderComponent(Badge, {
						variant: getValue() ? 'default' : 'destructive',
						class: 'h-8',
						children: createRawSnippet(() => ({
							render: () => `<p class="capitalize">${getValue() ? 'Active' : 'Inactive'}</p>`
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
					})
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
				accessorKey: 'preferred_weapon',
				header: 'Weapons',
				cell: ({ getValue }) => {
					const weapons = getValue() as string[];
					return renderSnippet(
						createRawSnippet(() => ({
							render: () =>
								`<div class="flex gap-1 flex-wrap">${weapons
									.map(
										(w) =>
											`<span class="bg-primary/10 text-primary rounded px-2 py-1 text-sm first-letter:capitalize">${w.replace(
												/[-_]/g,
												' '
											)}</span>`
									)
									.join('')}</div>`
						})),
						weapons
					);
				}
			},
			{
				accessorKey: 'membership_start_date',
				header: ({ column }) =>
					renderComponent(SortHeader, {
						onclick: () => column.toggleSorting(column.getIsSorted() === 'asc'),
						header: 'Member Since',
						class: 'p-2',
						sortDirection: column.getIsSorted()
					}),
				cell: ({ getValue }) => {
					const date = getValue() as string;
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () => `<p>${dayjs(value()).format('MMM D, YYYY')}</p>`
						})),
						date
					);
				}
			},
			{
				accessorKey: 'last_payment_date',
				header: ({ column }) =>
					renderComponent(SortHeader, {
						onclick: () => column.toggleSorting(column.getIsSorted() === 'asc'),
						header: 'Last Payment',
						class: 'p-2',
						sortDirection: column.getIsSorted()
					}),
				cell: ({ getValue }) => {
					const date = getValue() as string;
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () => `<p>${value() ? dayjs(value()).format('MMM D, YYYY') : 'Never'}</p>`
						})),
						date
					);
				}
			}
		],
		get data() {
			return membersQuery?.data?.data ?? [];
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
		state: {
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
		rowCount: membersQuery?.data?.count ?? 0,
		getCoreRowModel: getCoreRowModel(),
		getPaginationRowModel: getPaginationRowModel(),
		getSortedRowModel: getSortedRowModel()
	});

	const table = createSvelteTable(tableOptions);
</script>

<div class="flex w-full max-w-sm items-center space-x-2 mb-2 p-2">
	<Input
		value={searchQuery}
		onchange={(t) => onSearchChange(t.target?.value)}
		placeholder="Search members"
		class="max-w-md"
	/>

	{#if searchQuery !== ''}
		<Button variant="ghost" type="button" onclick={() => onSearchChange('')}>
			<Cross2 />
		</Button>
	{/if}
	{#if membersQuery.isFetching}
		<LoaderCircle />
	{/if}
</div>

<!-- Desktop Table View (hidden on mobile) -->
<div class="hidden md:block overflow-x-auto overflow-y-auto h-[70lvh]">
	<Table.Root class="w-full">
		<Table.Header class="sticky top-0 z-10 bg-white">
			{#each table.getHeaderGroups() as headerGroup (headerGroup.id)}
				<Table.Row>
					{#each headerGroup.headers as header (header.id)}
						<Table.Head class="text-black prose prose-p text-xs md:text-sm font-medium p-2">
							<FlexRender
								content={header.column.columnDef.header ?? ''}
								context={header.getContext() ?? {}}
							/>
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
			{/each}
		</Table.Body>
	</Table.Root>
</div>

<!-- Mobile Card View (hidden on desktop) -->
<div class="md:hidden overflow-y-auto h-[60svh] px-2 py-1">
	<div class="space-y-4">
		{#each table.getRowModel().rows as row (row.id)}
			<div class="bg-card text-card-foreground rounded-lg border shadow-sm p-4">
				<!-- Name and Actions Row -->
				<div class="flex justify-between items-center mb-3">
					<div class="font-medium text-base">
						{row.original.first_name}
						{row.original.last_name}
					</div>
					<div>
						<!-- Action buttons directly implemented -->
						<div class="flex gap-1">
							<!-- Emergency Contact -->
							<Button
								variant="ghost"
								size="icon"
								aria-label="Emergency Contact"
								onclick={() => (selectedMemberId = row.original.id)}
							>
								<Ambulance class="h-4 w-4" />
							</Button>

							<!-- Edit Button -->
							<Button
								variant="ghost"
								size="icon"
								aria-label="Edit member details"
								href={`/dashboard/members/${row.original.id}`}
							>
								<Edit class="h-4 w-4" />
							</Button>
						</div>
					</div>
				</div>

				<!-- Email -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Email</div>
					<div class="col-span-2 text-sm break-words">{row.original.email}</div>
				</div>

				<!-- Phone -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Phone</div>
					<div class="col-span-2 text-sm">{row.original.phone_number || 'N/A'}</div>
				</div>

				<!-- Gender -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Gender</div>
					<div class="col-span-2 text-sm capitalize">{row.original.gender || 'N/A'}</div>
				</div>

				<!-- Age -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Age</div>
					<div class="col-span-2 text-sm">{row.original.age || 'N/A'}</div>
				</div>

				<!-- Social Media Consent -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Social Consent</div>
					<div class="col-span-2">
						<Badge
							variant={row.original.social_media_consent === 'yes_recognizable' ||
							row.original.social_media_consent === 'yes_unrecognizable'
								? 'default'
								: 'destructive'}
							class="h-6"
						>
							<p class="capitalize">
								{row.original.social_media_consent?.replace('_', ' ') ?? 'Unknown'}
							</p>
						</Badge>
					</div>
				</div>

				<!-- Preferred Weapon -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Weapons</div>
					<div class="col-span-2 text-sm">
						{#if row.original.preferred_weapon}
							{#each row.original.preferred_weapon as weapon}
								<Badge variant="outline" class="mr-1 mb-1 capitalize">
									{weapon.replace(/_/g, ' ')}
								</Badge>
							{/each}
						{:else}
							None specified
						{/if}
					</div>
				</div>

				<!-- Member Since -->
				<div class="grid grid-cols-3 py-1">
					<div class="text-sm font-medium text-muted-foreground">Member Since</div>
					<div class="col-span-2 text-sm">
						{#if row.original.membership_start_date}
							{dayjs(row.original.membership_start_date).format('MMM D, YYYY')}
						{:else}
							Never
						{/if}
					</div>
				</div>
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
				{#each pageSizeOptions as pageSizeOption}
					<Select.Item value={pageSizeOption.toString()}>
						{pageSizeOption}
					</Select.Item>
				{/each}
			</Select.Content>
		</Select.Root>
	</div>
	<div class="w-full md:w-auto flex justify-center md:justify-end">
		<Pagination.Root
			count={membersQuery?.data?.count ?? 0}
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
							<Pagination.Item class={page.value !== currentPage && page.value !== currentPage - 1 && page.value !== currentPage + 1 ? 'hidden sm:block' : ''}>
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

<Sheet.Root
	open={Boolean(selectedMemberQuery?.data) && selectedMemberId !== null}
	onOpenChange={(open) => (selectedMemberId = open ? selectedMemberId : null)}
>
	<Sheet.Content side="right" class="w-[400px]">
		<Sheet.Header>
			<Sheet.Title class="flex items-center gap-2">
				<Ambulance class="h-5 w-5 text-destructive" />
				Emergency Contact
			</Sheet.Title>
		</Sheet.Header>
		<div class="grid gap-4 px-6 py-4">
			<div class="rounded-lg border border-destructive/20 bg-destructive/5 p-4">
				<div class="flex flex-col space-y-3">
					<div>
						<span class="text-sm font-medium text-muted-foreground">Member Name</span>
						<div class="text-base font-medium">
							{selectedMemberQuery.data?.first_name}
							{selectedMemberQuery.data?.last_name}
						</div>
					</div>
					<div class="border-t border-destructive/20 pt-3">
						<span class="text-sm font-medium text-destructive">Emergency Contact Details</span>
						<div class="mt-2 space-y-2">
							<div>
								<span class="text-sm font-medium text-muted-foreground">Name</span>
								<div class="text-base">{selectedMemberQuery.data?.next_of_kin_name}</div>
							</div>
							<div>
								<span class="text-sm font-medium text-muted-foreground">Phone</span>
								<div class="text-base font-medium text-destructive">
									{selectedMemberQuery.data?.next_of_kin_phone}
								</div>
							</div>
						</div>
					</div>
				</div>
			</div>
		</div>
	</Sheet.Content>
</Sheet.Root>
