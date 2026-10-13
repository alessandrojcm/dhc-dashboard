/**
 * Runes controller for the quartermaster Items page (ALE-416).
 *
 * Owns everything on the page that is not markup:
 *
 * - the list request, URL-backed through `createCursorTableUrl` (search,
 *   archive and availability filters, cursor): search and filters replace
 *   the history entry and drop the cursor, paging pushes one;
 * - routed selection: `[[itemId]]` is an item's code (or id), `new` the
 *   create form, and `?slug=` a deep link that resolves to the item's route;
 * - the drafts behind the create and management forms, and their dirty state;
 * - every Item command's outcome: the toast, what is refreshed, and the
 *   submit button's success flash.
 *
 * Every Item command is a remote form in `data.remote.ts`; the page spreads
 * `form.preflight(schema).enhance(workbench.enhance.<command>)`, so the
 * controller sees each submission's `{ ok, data | error }` result. Phoenix
 * stays the only authority on an item: a success adopts the item Phoenix
 * answered with, never a locally edited copy.
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
import { apiErrorMessage } from "#lib/api-error.js";
import {
	createCursorTableUrl,
	type CursorTableNavigate,
} from "#lib/cursor-table-url.svelte.js";
import {
	draftFromItem,
	encodePropertyDraft,
	type PropertyDraft,
	sameDraft,
	withDraftInput,
} from "#lib/inventory/property-values.js";

export const ITEMS_PATH = "/dashboard/inventory/items";

/** How long a submit button shows its success state. */
const SUCCESS_FLASH_MS = 650;

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

/** The forms whose submit button flashes on success. */
export type FlashedForm =
	| "create"
	| "details"
	| "placement"
	| "category"
	| "maintenance";

/** Which property draft a value control writes to. */
export type DraftTarget = "create" | "details" | "category";

/** What an Item command's remote form answers (`inventoryCommand`). */
export type ItemCommandResult =
	| { ok: true; data: InventoryOperatorItem }
	| { ok: false; error: string };

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

type ItemFields = {
	notes: string;
	values: PropertyDraft;
	containerId: string;
	categoryId: string;
	categoryValues: PropertyDraft;
	maintenanceReason: string;
	maintenanceEndNote: string;
	archiveReason: string;
};

/** The management forms' drafts, and the item they started from. */
function itemDrafts(item: InventoryOperatorItem) {
	const fields = $state<ItemFields>({
		notes: item.notes ?? "",
		values: draftFromItem(item),
		containerId: item.containerId ?? "",
		categoryId: item.categoryId,
		categoryValues: draftFromItem(item),
		maintenanceReason: "",
		maintenanceEndNote: "",
		archiveReason: "",
	});
	return { item, fields };
}

export function createItemWorkbench(deps: ItemWorkbenchDeps = {}) {
	const queryClient = deps.queryClient ?? useQueryClient();
	const client = () => queryClient;
	const requests = deps.requests ?? {};
	const url = deps.url ?? (() => page.url);
	const itemId = deps.itemId ?? (() => page.params.itemId);
	const visit = deps.visit ?? ((href: string) => goto(href));
	const notify = deps.notify ?? toast;
	const successFlashMs = deps.successFlashMs ?? SUCCESS_FLASH_MS;

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

	const routeId = $derived(itemId());
	const creating = $derived(routeId === "new");
	const managedId = $derived(routeId && !creating ? routeId : undefined);

	const list = createQuery(
		() => ({
			...inventoryItemsListOptions({ query: listRequest }),
			...(requests.list && {
				queryFn: () => requests.list!({ query: listRequest }),
			}),
			enabled: !routeId,
			placeholderData: keepPreviousData,
			select: (response: InventoryItemsListResponse) => response.data,
		}),
		client,
	);

	/** The list's own query string, carried to item routes and back. */
	const listSearch = $derived.by(() => {
		const params = new URLSearchParams(url().searchParams.toString());
		params.delete("slug");
		const query = params.toString();
		return query ? `?${query}` : "";
	});

	const listHref = () => `${ITEMS_PATH}${listSearch}`;
	const itemHref = (slug: string) => `${ITEMS_PATH}/${slug}${listSearch}`;

	// ── Routed selection ─────────────────────────────────────────────────

	function showQuery(slugOrId: string) {
		return {
			...inventoryItemsShowOptions({ path: { slugOrId } }),
			...(requests.show && {
				queryFn: () => requests.show!({ path: { slugOrId } }),
			}),
		};
	}

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

	// Deep link for the loan queue's "Open item" maintenance links: `?slug=`
	// resolves through the show endpoint (archive-agnostic) and lands on the
	// item's route. Day-to-day code search goes through the list's `q`.
	let lookedUpSlug: string | undefined;
	$effect(() => {
		const slug = url().searchParams.get("slug")?.trim();
		if (!slug || slug === lookedUpSlug) return;
		lookedUpSlug = slug;
		void lookUpSlug(slug);
	});

	async function lookUpSlug(slug: string) {
		try {
			const response = await queryClient.fetchQuery(showQuery(slug));
			await visit(`${ITEMS_PATH}/${response.data.slug}`);
		} catch (cause) {
			notify.error(apiErrorMessage(cause, "No item matches that code"));
		}
	}

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

	// Reset whenever another item is selected; a command's success replaces
	// them with drafts of the item Phoenix answered with.
	let drafts = $derived.by(() => {
		if (!selectedSlug) return undefined;
		return untrack(() => (selected ? itemDrafts(selected) : undefined));
	});
	// Writable deriveds: reading `selectedSlug` resets them to their initial
	// value whenever another item is selected; the page may assign them.
	let managementTab = $derived.by((): ManagementTab => {
		void selectedSlug;
		return "details";
	});
	let deleteConfirmOpen = $derived.by(() => {
		void selectedSlug;
		return false;
	});

	const createDefinitions = definitionsOf(() => create.categoryId);
	const detailsDefinitions = definitionsOf(() => drafts?.item.categoryId);
	const categoryDefinitions = definitionsOf(() => drafts?.fields.categoryId);

	const dirty = $derived.by(() => {
		if (!drafts) return { details: false, placement: false, category: false };
		const { item, fields } = drafts;
		const stored = draftFromItem(item);
		return {
			details:
				fields.notes.trim() !== (item.notes ?? "") ||
				!sameDraft(fields.values, stored),
			placement: fields.containerId !== (item.containerId ?? ""),
			category:
				fields.categoryId !== item.categoryId ||
				!sameDraft(fields.categoryValues, stored),
		};
	});

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

	// ── Command outcomes ─────────────────────────────────────────────────

	let flashing = $state<FlashedForm | null>(null);
	let flashTimer: ReturnType<typeof setTimeout> | undefined;
	$effect(() => () => clearTimeout(flashTimer));

	function flash(form: FlashedForm, after?: () => void) {
		flashing = form;
		clearTimeout(flashTimer);
		flashTimer = setTimeout(() => {
			flashing = null;
			after?.();
		}, successFlashMs);
	}

	async function invalidateLists(slug: string) {
		await Promise.all([
			// Partial key: matches every filtered or paged Item list.
			queryClient.invalidateQueries({ queryKey: inventoryItemsListQueryKey() }),
			queryClient.invalidateQueries({
				queryKey: inventoryItemsListMaintenanceQueryKey({
					path: { slugOrId: slug },
				}),
			}),
		]);
	}

	/** Adopts the item Phoenix answered with: detail, drafts, then lists. */
	async function adopt(item: InventoryOperatorItem) {
		if (managedId) {
			queryClient.setQueryData<InventoryItemsShowResponse>(
				inventoryItemsShowQueryKey({ path: { slugOrId: managedId } }),
				{ data: item },
			);
		}
		drafts = itemDrafts(item);
		await invalidateLists(item.slug);
	}

	/**
	 * An `enhance` callback: submits, then hands a result (never a
	 * validation failure, which the form shows itself) to `outcome`.
	 */
	function submitted(
		outcome: (result: ItemCommandResult) => void | Promise<void>,
	) {
		return async (form: ItemCommandSubmission) => {
			if (!(await form.submit())) return;
			const result = form.result;
			if (result) await outcome(result);
		};
	}

	/**
	 * A management form's command. A refusal stays inline in the form; a
	 * success adopts the item and flashes the form's button.
	 */
	function edited(form: FlashedForm) {
		return submitted(async (result) => {
			if (!result.ok) return;
			flash(form);
			await adopt(result.data);
		});
	}

	/** Archive and restore answer with a toast either way. */
	function lifecycle(success: string) {
		return submitted(async (result) => {
			if (!result.ok) {
				notify.error(result.error);
				return;
			}
			notify.success(success);
			await adopt(result.data);
		});
	}

	const enhance = {
		/**
		 * Flashes the button, then opens the new item's route. No toast: it
		 * would cover the next submit.
		 */
		create: submitted(async (result) => {
			if (!result.ok) return;
			const item = result.data;
			const href = itemHref(item.slug);
			queryClient.setQueryData<InventoryItemsShowResponse>(
				inventoryItemsShowQueryKey({ path: { slugOrId: item.slug } }),
				{ data: item },
			);
			flash("create", () => {
				resetCreate();
				void visit(href);
			});
			await invalidateLists(item.slug);
		}),
		update: edited("details"),
		move: edited("placement"),
		changeCategory: edited("category"),
		startMaintenance: edited("maintenance"),
		endMaintenance: edited("maintenance"),
		archive: lifecycle("Item archived"),
		restore: lifecycle("Item restored"),
		/** Returns to the list: the navigation is the feedback, no toast. */
		delete: submitted(async (result) => {
			if (!result.ok) {
				notify.error(result.error);
				return;
			}
			deleteConfirmOpen = false;
			if (managedId) {
				queryClient.removeQueries({
					queryKey: inventoryItemsShowQueryKey({
						path: { slugOrId: managedId },
					}),
				});
			}
			await visit(listHref());
			await queryClient.invalidateQueries({
				queryKey: inventoryItemsListQueryKey(),
			});
		}),
	};

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
			return `${ITEMS_PATH}/new${listSearch}`;
		},
		itemHref,

		// Routed selection
		/** Whether the route is an item or the create form, not the list. */
		get routed() {
			return Boolean(routeId);
		},
		get creating() {
			return creating;
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
			return deleteConfirmOpen;
		},
		set deleteConfirmOpen(open: boolean) {
			deleteConfirmOpen = open;
		},

		// Commands
		enhance,
		/** Whether `form`'s submit button is showing its success state. */
		succeeded(form: FlashedForm) {
			return flashing === form;
		},
	};
}

export type ItemWorkbench = ReturnType<typeof createItemWorkbench>;
