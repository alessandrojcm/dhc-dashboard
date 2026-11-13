/**
 * Runes controller for the quartermaster Items page (ALE-416, ALE-451).
 *
 * Owns everything on the page that is not markup:
 *
 * - the list request, URL-backed through `createCursorTableUrl` (search,
 *   archive and availability filters, cursor): search and filters replace
 *   the history entry and drop the cursor, paging pushes one;
 * - the reads the forms need, and the drafts behind the create and
 *   management forms with their dirty state (independent runes state);
 * - one `itemWorkbenchMachine` actor (`item-workbench-machine.ts`), created
 *   with the controller and stopped with it, which owns the routed mode
 *   (`[[itemId]]` is an item's code or id, `new` the create form, `?slug=` a
 *   deep link that resolves to the item's route) and every Item command's
 *   outcome: what is adopted and refreshed, which drafts rebase, the toast,
 *   the submit button's success flash and the navigation after create and
 *   delete. The controller feeds it the URL and each command's answer, and
 *   provides its effects (query cache, `visit`, toasts, `rebasedDrafts`).
 *
 * Every Item command is a remote form in `data.remote.ts`; the page spreads
 * `form.preflight(schema).enhance(workbench.enhance.<command>)`, so the
 * controller sees each submission's `{ ok, data | error }` result. Phoenix
 * stays the only authority on an item: a success adopts the item Phoenix
 * answered with, never a locally edited copy. Only the submitting form's drafts
 * start again from that answer; an unsaved edit in another form survives unless
 * the answer changed what that form edits (`rebasedDrafts`).
 */
import { goto } from "$app/navigation";
import { page } from "$app/state";
import {
	createQuery,
	keepPreviousData,
	useQueryClient,
	type QueryClient,
} from "@tanstack/svelte-query";
import {
	type InventoryCategoriesIndexResponse,
	type InventoryContainersIndexResponse,
	type InventoryItemsListData,
	type InventoryItemsListMaintenanceData,
	type InventoryItemsListMaintenanceResponse,
	type InventoryItemsListResponse,
	type InventoryItemsShowData,
	type InventoryItemsShowResponse,
	type InventoryOperatorItem,
	type InventoryPropertyDefinition,
	type InventoryStructureListDefinitionsData,
	type InventoryStructureListDefinitionsResponse,
	type Options,
	inventoryCategoriesIndexOptions,
	inventoryContainersIndexOptions,
	inventoryItemsListMaintenanceOptions,
	inventoryItemsListMaintenanceQueryKey,
	inventoryItemsListOptions,
	inventoryItemsListQueryKey,
	inventoryItemsShowOptions,
	inventoryItemsShowQueryKey,
	inventoryStructureListDefinitionsOptions,
} from "@dhc/api-client";
import { untrack } from "svelte";
import { toast } from "svelte-sonner";
import { createActor, fromPromise } from "xstate";
import {
	createCursorTableUrl,
	type CursorTableNavigate,
} from "#lib/cursor-table-url.svelte.js";
import {
	draftFromItem,
	encodePropertyDraft,
	type PropertyDraft,
	withDraftInput,
} from "#lib/inventory/property-values.js";
import {
	dirtyOf,
	type ItemDrafts,
	type ItemFields,
	itemDrafts,
	rebasedDrafts,
} from "./item-drafts";
import {
	type FlashedForm,
	type ItemCommand,
	type ItemCommandResult,
	itemsHref,
	itemWorkbenchMachine,
	itemWorkbenchView,
	type WorkbenchRoute,
} from "./item-workbench-machine";

export {
	type FlashedForm,
	type ItemCommandResult,
	ITEMS_PATH,
} from "./item-workbench-machine";

export type AvailabilityFilter =
	| "all"
	| "available"
	| "on_loan"
	| "maintenance";
export type ArchiveFilter = NonNullable<
	NonNullable<InventoryItemsListData["query"]>["archived"]
>;

type FilterOption<T extends string> = { value: T; label: string };

export const AVAILABILITY_FILTERS: FilterOption<AvailabilityFilter>[] = [
	{ value: "all", label: "All" },
	{ value: "available", label: "Available" },
	{ value: "on_loan", label: "On loan" },
	{ value: "maintenance", label: "Maintenance" },
];

export const ARCHIVE_FILTERS: FilterOption<ArchiveFilter>[] = [
	{ value: "exclude", label: "Active" },
	{ value: "include", label: "All" },
	{ value: "only", label: "Archived" },
];

const AVAILABILITY_LABELS = {
	available: "Available",
	on_loan: "On loan",
	maintenance: "Maintenance",
	archived: "Archived",
} as const satisfies Record<
	InventoryOperatorItem["availability"]["status"],
	string
>;

export function availabilityLabel(
	status: InventoryOperatorItem["availability"]["status"],
): string {
	return AVAILABILITY_LABELS[status];
}

function pickOption<T extends string>(
	options: readonly { value: T }[],
	value: string | null,
	fallback: T,
): T {
	return options.find((option) => option.value === value)?.value ?? fallback;
}

const MANAGEMENT_TABS = [
	{ value: "details" },
	{ value: "placement" },
	{ value: "maintenance" },
] as const;

export type ManagementTab = (typeof MANAGEMENT_TABS)[number]["value"];

/** Which property draft a value control writes to. */
export type DraftTarget = "create" | "details" | "category";

/** The part of a remote form's `enhance` instance the controller uses. */
export type ItemCommandSubmission = {
	submit(): PromiseLike<boolean>;
	readonly result: ItemCommandResult | undefined;
};

export type ItemWorkbenchNotify = {
	success(message: string): void;
	error(message: string): void;
};

type Request<TData, TResponse> = (options: TData) => Promise<TResponse>;

/** Read functions; each defaults to the generated Phoenix client. */
export type ItemWorkbenchRequests = {
	list: Request<Options<InventoryItemsListData>, InventoryItemsListResponse>;
	show: Request<Options<InventoryItemsShowData>, InventoryItemsShowResponse>;
	categories: () => Promise<InventoryCategoriesIndexResponse>;
	containers: () => Promise<InventoryContainersIndexResponse>;
	definitions: Request<
		Options<InventoryStructureListDefinitionsData>,
		InventoryStructureListDefinitionsResponse
	>;
	maintenance: Request<
		Options<InventoryItemsListMaintenanceData>,
		InventoryItemsListMaintenanceResponse
	>;
};

export type ItemWorkbenchDeps = {
	/** Defaults to the client from Svelte context. */
	queryClient?: QueryClient;
	requests?: Partial<ItemWorkbenchRequests>;
	/** URL source; defaults to `page.url` from `$app/state`. */
	url?: () => URL;
	/** The `[[itemId]]` route param; defaults to `page.params.itemId`. */
	itemId?: () => string | undefined;
	/** List-state history writes; defaults to `createCursorTableUrl`'s. */
	navigate?: CursorTableNavigate;
	/** Route changes (selection, after create/delete); defaults to `goto`. */
	visit?: (href: string) => void | Promise<void>;
	/** Defaults to svelte-sonner's `toast`. */
	notify?: ItemWorkbenchNotify;
	successFlashMs?: number;
};

type CreateFields = {
	categoryId: string;
	containerId: string;
	notes: string;
	values: PropertyDraft;
};

/** Live drafts: the page binds to `fields`, so they are deeply reactive. */
function liveDrafts({ item, fields }: ItemDrafts): ItemDrafts {
	const live = $state<ItemFields>(fields);
	return { item, fields: live };
}

export function createItemWorkbench(deps: ItemWorkbenchDeps = {}) {
	const queryClient = deps.queryClient ?? useQueryClient();
	const client = () => queryClient;
	const requests = deps.requests ?? {};
	const url = deps.url ?? (() => page.url);
	const itemId = deps.itemId ?? (() => page.params.itemId);
	const visit = deps.visit ?? ((href: string) => goto(href));
	const notify = deps.notify ?? toast;

	// ── List ──────────────────────────────────────────────────────────────

	const table = createCursorTableUrl({
		sort: { fields: { slug: "slug" }, default: "slug" },
		filters: ["archived", "availability"],
		defaultPageSize: 25,
		...(deps.url && { url: deps.url }),
		...(deps.navigate && { navigate: deps.navigate }),
	});

	const archived = $derived(
		pickOption(ARCHIVE_FILTERS, table.filter("archived"), "exclude"),
	);
	const availability = $derived(
		pickOption(AVAILABILITY_FILTERS, table.filter("availability"), "all"),
	);
	const listRequest = $derived.by(
		(): NonNullable<InventoryItemsListData["query"]> => {
			const { limit, cursor, q, direction } = table.request;
			return {
				limit,
				direction,
				archived,
				...(availability !== "all" && { availability }),
				...(q && { q }),
				...(cursor && { cursor }),
			};
		},
	);

	/** The list's own query string, carried to item routes and back. */
	const listSearch = $derived.by(() => {
		const params = new URLSearchParams(url().searchParams.toString());
		params.delete("slug");
		const query = params.toString();
		return query ? `?${query}` : "";
	});

	const listHref = () => itemsHref(listSearch);
	const itemHref = (slug: string) => itemsHref(listSearch, slug);

	// ── Workflow ─────────────────────────────────────────────────────────

	function currentRoute(): WorkbenchRoute {
		return {
			routeId: itemId(),
			slug: url().searchParams.get("slug")?.trim() || undefined,
			search: listSearch,
		};
	}

	function showQuery(slugOrId: string) {
		return {
			...inventoryItemsShowOptions({ path: { slugOrId } }),
			...(requests.show && {
				queryFn: () => requests.show!({ path: { slugOrId } }),
			}),
		};
	}

	const actor = createActor(
		itemWorkbenchMachine.provide({
			actors: {
				lookUpItem: fromPromise(async ({ input }) => {
					const response = await queryClient.fetchQuery(showQuery(input.slug));
					return response.data;
				}),
			},
			actions: {
				adopt: (_, { routeId, item }) => {
					queryClient.setQueryData<InventoryItemsShowResponse>(
						inventoryItemsShowQueryKey({ path: { slugOrId: routeId } }),
						{ data: item },
					);
				},
				forget: (_, { routeId }) => {
					queryClient.removeQueries({
						queryKey: inventoryItemsShowQueryKey({
							path: { slugOrId: routeId },
						}),
					});
				},
				invalidateLists: (_, { slug }) => {
					// Partial key: matches every filtered or paged Item list.
					void queryClient.invalidateQueries({
						queryKey: inventoryItemsListQueryKey(),
					});
					if (slug) {
						void queryClient.invalidateQueries({
							queryKey: inventoryItemsListMaintenanceQueryKey({
								path: { slugOrId: slug },
							}),
						});
					}
				},
				rebase: (_, { item, own }) => {
					const current = drafts && {
						item: drafts.item,
						fields: $state.snapshot(drafts.fields),
					};
					drafts = liveDrafts(rebasedDrafts(current, item, own));
				},
				resetCreate: () => resetCreate(),
				visit: (_, { href }) => void visit(href),
				notifySuccess: (_, { message }) => notify.success(message),
				notifyError: (_, { message }) => notify.error(message),
			},
		}),
		{
			input: {
				...untrack(currentRoute),
				...(deps.successFlashMs !== undefined && {
					successFlashMs: deps.successFlashMs,
				}),
			},
		},
	);
	let snapshot = $state.raw(actor.getSnapshot());
	actor.subscribe((next) => {
		snapshot = next;
	});
	actor.start();
	// Stopping cancels the flash, a pending open of a created item and a
	// deep-link lookup; a command's late answer is then dropped.
	$effect(() => () => actor.stop());

	function sync(route: WorkbenchRoute) {
		if (actor.getSnapshot().status !== "active") return;
		actor.send({ type: "ROUTED", ...route });
	}

	// Before the DOM updates, so markup never shows the previous route's mode.
	$effect.pre(() => {
		const route = currentRoute();
		untrack(() => sync(route));
	});

	const view = $derived(itemWorkbenchView(snapshot));
	const managedId = $derived(view.managedId);

	const list = createQuery(
		() => ({
			...inventoryItemsListOptions({ query: listRequest }),
			...(requests.list && {
				queryFn: () => requests.list!({ query: listRequest }),
			}),
			enabled: view.mode === "list",
			placeholderData: keepPreviousData,
			select: (response: InventoryItemsListResponse) => response.data,
		}),
		client,
	);

	// ── Routed selection ─────────────────────────────────────────────────

	const routedItem = createQuery(
		() => ({
			...showQuery(managedId ?? ""),
			enabled: Boolean(managedId),
			select: (response: InventoryItemsShowResponse) => response.data,
		}),
		client,
	);

	const selected = $derived(managedId ? routedItem.data : undefined);
	// A primitive, so a refetch of the same item does not reset the drafts.
	const selectedSlug = $derived(selected?.slug);

	// ── Reads the forms need ─────────────────────────────────────────────

	const categories = createQuery(
		() => ({
			...inventoryCategoriesIndexOptions(),
			...(requests.categories && { queryFn: requests.categories }),
			select: (response: InventoryCategoriesIndexResponse) =>
				response.data.categories,
		}),
		client,
	);
	const containers = createQuery(
		() => ({
			...inventoryContainersIndexOptions(),
			...(requests.containers && { queryFn: requests.containers }),
			select: (response: InventoryContainersIndexResponse) =>
				response.data.containers,
		}),
		client,
	);

	function definitionsOf(categoryId: () => string | undefined) {
		return createQuery(() => {
			const path = { categoryId: categoryId() ?? "" };
			return {
				...inventoryStructureListDefinitionsOptions({ path }),
				...(requests.definitions && {
					queryFn: () => requests.definitions!({ path }),
				}),
				enabled: Boolean(categoryId()),
				select: (response: InventoryStructureListDefinitionsResponse) =>
					response.data.definitions,
			};
		}, client);
	}

	const maintenance = createQuery(() => {
		const path = { slugOrId: selected?.slug ?? "" };
		return {
			...inventoryItemsListMaintenanceOptions({ path }),
			...(requests.maintenance && {
				queryFn: () => requests.maintenance!({ path }),
			}),
			enabled: Boolean(selected),
			select: (response: InventoryItemsListMaintenanceResponse) =>
				response.data.periods,
		};
	}, client);

	const categoryOptions = $derived(
		(categories.data ?? []).map((category) => ({
			value: category.id,
			label: category.name,
		})),
	);
	const containerOptions = $derived(
		(containers.data ?? [])
			.filter((container) => !container.archivedAt)
			.map((container) => ({ value: container.id, label: container.name })),
	);

	// ── Drafts ───────────────────────────────────────────────────────────

	const create = $state<CreateFields>({
		categoryId: "",
		containerId: "",
		notes: "",
		values: {},
	});

	function resetCreate() {
		create.categoryId = "";
		create.containerId = "";
		create.notes = "";
		create.values = {};
	}

	// Reset whenever another item is selected; a command's success rebases
	// them on the item Phoenix answered with (`rebasedDrafts`).
	let drafts = $derived.by(() => {
		if (!selectedSlug) return undefined;
		return untrack(() =>
			selected ? liveDrafts(itemDrafts(selected)) : undefined,
		);
	});
	// Writable deriveds: reading `selectedSlug` resets them to their initial
	// value whenever another item is selected; the page may assign them.
	let managementTab = $derived.by((): ManagementTab => {
		void selectedSlug;
		return "details";
	});

	const createDefinitions = definitionsOf(() => create.categoryId);
	const detailsDefinitions = definitionsOf(() => drafts?.item.categoryId);
	const categoryDefinitions = definitionsOf(() => drafts?.fields.categoryId);

	const dirty = $derived.by(() =>
		drafts
			? dirtyOf(drafts)
			: { details: false, placement: false, category: false },
	);

	function setValue(
		target: DraftTarget,
		definition: Pick<InventoryPropertyDefinition, "id" | "valueType">,
		input: string,
	) {
		if (target === "create") {
			create.values = withDraftInput(create.values, definition, input);
		} else if (drafts && target === "details") {
			drafts.fields.values = withDraftInput(
				drafts.fields.values,
				definition,
				input,
			);
		} else if (drafts) {
			drafts.fields.categoryValues = withDraftInput(
				drafts.fields.categoryValues,
				definition,
				input,
			);
		}
	}

	/** A new category's properties start empty. */
	function chooseCreateCategory(categoryId: string) {
		if (categoryId === create.categoryId) return;
		create.categoryId = categoryId;
		create.values = {};
	}

	/**
	 * The change-category draft. Its values start empty for another
	 * category, and return to the stored ones for the item's own.
	 */
	function chooseNewCategory(categoryId: string) {
		if (!drafts || categoryId === drafts.fields.categoryId) return;
		drafts.fields.categoryId = categoryId;
		drafts.fields.categoryValues =
			categoryId === drafts.item.categoryId ? draftFromItem(drafts.item) : {};
	}

	// ── Commands ─────────────────────────────────────────────────────────

	/**
	 * An `enhance` callback: submits, then hands Phoenix's answer (never a
	 * validation failure, which the form shows itself) to the machine, tagged
	 * with the route it was submitted under.
	 */
	function submitted(command: ItemCommand) {
		return async (form: ItemCommandSubmission) => {
			untrack(() => sync(currentRoute()));
			const { generation, route } = actor.getSnapshot().context;
			if (!(await form.submit())) return;
			const result = form.result;
			if (!result) return;
			// The route may have changed while Phoenix answered.
			untrack(() => sync(currentRoute()));
			if (actor.getSnapshot().status !== "active") return;
			actor.send({
				type: "SETTLED",
				command,
				generation,
				routeId: route.routeId,
				result,
			});
		};
	}

	const enhance = {
		create: submitted("create"),
		update: submitted("update"),
		move: submitted("move"),
		changeCategory: submitted("changeCategory"),
		startMaintenance: submitted("startMaintenance"),
		endMaintenance: submitted("endMaintenance"),
		archive: submitted("archive"),
		restore: submitted("restore"),
		delete: submitted("delete"),
	} satisfies Record<ItemCommand, ReturnType<typeof submitted>>;

	return {
		// List
		list,
		get items() {
			return list.data?.items ?? [];
		},
		get totalCount() {
			return list.data?.totalCount ?? 0;
		},
		/** The search box's draft; the URL follows after a debounce. */
		get search() {
			return table.search;
		},
		setSearch: (value: string) => table.setSearch(value),
		/** Whether the list is narrowed by a search, for the empty state. */
		get searching() {
			return Boolean(table.request.q);
		},
		get archived() {
			return archived;
		},
		/** Takes a select's value; one the page does not offer is ignored. */
		setArchived(value: string) {
			const next = pickOption(ARCHIVE_FILTERS, value, archived);
			table.setFilter("archived", next === "exclude" ? null : next);
		},
		get availability() {
			return availability;
		},
		/** Takes a select's value; one the page does not offer is ignored. */
		setAvailability(value: string) {
			const next = pickOption(AVAILABILITY_FILTERS, value, availability);
			table.setFilter("availability", next === "all" ? null : next);
		},
		get activeFilterCount() {
			return Number(availability !== "all") + Number(archived !== "exclude");
		},
		clearFilters() {
			table.setFilters({ archived: null, availability: null });
		},
		get paged() {
			return Boolean(table.request.cursor || list.data?.nextCursor);
		},
		get previousCursor() {
			return list.data?.previousCursor ?? null;
		},
		get nextCursor() {
			return list.data?.nextCursor ?? null;
		},
		previousPage() {
			table.goTo(list.data?.previousCursor);
		},
		nextPage() {
			table.goTo(list.data?.nextCursor);
		},
		/** The list, with its search and filters. */
		get listHref() {
			return listHref();
		},
		get newItemHref() {
			return itemsHref(listSearch, "new");
		},
		itemHref,

		// Routed selection
		/** Whether the route is an item or the create form, not the list. */
		get routed() {
			return view.mode !== "list";
		},
		get creating() {
			return view.mode === "create";
		},
		routedItem,
		/** The managed item, once loaded. */
		get selected() {
			return selected;
		},

		// Reads
		categories,
		containers,
		maintenance,
		createDefinitions,
		detailsDefinitions,
		categoryDefinitions,
		get categoryOptions() {
			return categoryOptions;
		},
		get containerOptions() {
			return containerOptions;
		},

		// Drafts
		/** The create form's draft; `categoryId` goes through `chooseCreateCategory`. */
		create,
		/** The managed item's drafts; `categoryId` goes through `chooseNewCategory`. */
		get drafts() {
			return drafts?.fields;
		},
		/** The property drafts as their hidden inputs carry them. */
		get encoded() {
			return {
				create: encodePropertyDraft(create.values),
				details: encodePropertyDraft(drafts?.fields.values ?? {}),
				category: encodePropertyDraft(drafts?.fields.categoryValues ?? {}),
			};
		},
		get dirty() {
			return dirty;
		},
		get canCreate() {
			return Boolean(
				create.categoryId && create.containerId && !createDefinitions.isPending,
			);
		},
		setValue,
		chooseCreateCategory,
		chooseNewCategory,
		get managementTab() {
			return managementTab;
		},
		set managementTab(tab: string) {
			managementTab = pickOption(MANAGEMENT_TABS, tab, managementTab);
		},
		get deleteConfirmOpen() {
			return view.deleteConfirmOpen;
		},
		set deleteConfirmOpen(open: boolean) {
			actor.send({ type: "CONFIRM_DELETE", open });
		},

		// Commands
		enhance,
		/** Whether `form`'s submit button is showing its success state. */
		succeeded(form: FlashedForm) {
			return view.flashing === form;
		},
	};
}

export type ItemWorkbench = ReturnType<typeof createItemWorkbench>;
