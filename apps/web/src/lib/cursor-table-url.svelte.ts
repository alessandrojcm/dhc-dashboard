/**
 * URL-backed state for a cursor-paginated, sortable, searchable table.
 *
 * The URL is the only source of truth for what the table requests; this
 * module owns the translation between search params and the generated API
 * client's `query` object (including the column-id → API sort-field map),
 * and the history policy for each kind of change:
 *
 * - search, filters, sort and page size replace the current entry and drop the
 *   cursor (the cursor is only valid for the query that produced it);
 * - cursor paging pushes an entry, so Back returns to the previous page.
 *
 * Search keeps a local draft so the input updates immediately; the URL is
 * written after a debounce, or together with any earlier replace.
 */
import type {
	OnChangeFn,
	PaginationState,
	SortingState,
	Updater,
} from "@tanstack/table-core";
import { goto } from "$app/navigation";
import { page } from "$app/state";
import {
	isPageSize,
	parsePageSize,
	transitionCursorQuery,
	type PageSize,
} from "#lib/cursor-query.js";

export type SortDirection = "asc" | "desc";

export type CursorTableNavigate = (
	href: string,
	options: { replace: boolean },
) => void | Promise<void>;

export type CursorTableUrlOptions<
	SortId extends string,
	ApiSort extends string,
	Filter extends string,
> = {
	/** Key namespace: `""` → `q`, `cursor`, …; `"invite"` → `inviteQ`, `inviteCursor`, …. */
	prefix?: string;
	sort: {
		/** Column id (as written to the URL) → API sort field. */
		fields: Readonly<Record<SortId, ApiSort>>;
		default: NoInfer<SortId>;
		defaultDirection?: SortDirection;
	};
	/** Free-form string filters, written under the prefixed key. */
	filters?: readonly Filter[];
	/** Search debounce in milliseconds. */
	debounceMs?: number;
	/** URL source; defaults to `page.url` from `$app/state`. */
	url?: () => URL;
	/** Navigation; defaults to `goto` from `$app/navigation`. */
	navigate?: CursorTableNavigate;
};

export type CursorTableRequest<
	ApiSort extends string,
	Filter extends string,
> = {
	limit: PageSize;
	cursor?: string;
	q?: string;
	sort: ApiSort;
	direction: SortDirection;
} & { [K in Filter]?: string };

export type CursorTableUrl<
	ApiSort extends string,
	Filter extends string,
	SortId extends string = string,
> = {
	/** Ready to pass as the generated client's `query`. */
	readonly request: CursorTableRequest<ApiSort, Filter>;
	/** The sort in effect, after falling back to the defaults. */
	readonly sort: { readonly id: SortId; readonly direction: SortDirection };
	/** The search draft: what the input shows. */
	readonly search: string;
	setSearch(value: string): void;
	/** Writes a pending (debounced) search now; a no-op when none is pending. */
	submitSearch(): void;
	filter(key: Filter): string | null;
	setFilter(key: Filter, value: string | null): void;
	readonly pageSize: PageSize;
	setPageSize(pageSize: number): void;
	/** Moves to a page; a missing cursor is ignored. */
	goTo(cursor: string | null | undefined): void;
	/** TanStack Table state and change handlers for manual sorting and pagination. */
	readonly table: {
		readonly state: {
			readonly sorting: SortingState;
			readonly pagination: PaginationState;
		};
		onSortingChange: OnChangeFn<SortingState>;
		onPaginationChange: OnChangeFn<PaginationState>;
	};
};

const DEFAULT_DEBOUNCE_MS = 300;

function defaultNavigate(href: string, options: { replace: boolean }) {
	return goto(href, { reset: false, replace: options.replace });
}

function resolve<T>(updater: Updater<T>, current: T): T {
	return updater instanceof Function ? updater(current) : updater;
}

export function createCursorTableUrl<
	SortId extends string,
	ApiSort extends string,
	Filter extends string = never,
>(
	options: CursorTableUrlOptions<SortId, ApiSort, Filter>,
): CursorTableUrl<ApiSort, Filter, SortId> {
	const prefix = options.prefix ?? "";
	const readUrl = options.url ?? (() => page.url);
	const navigate = options.navigate ?? defaultNavigate;
	const debounceMs = options.debounceMs ?? DEFAULT_DEBOUNCE_MS;
	const sortFields = options.sort.fields;
	const defaultDirection = options.sort.defaultDirection ?? "asc";
	const filters = options.filters ?? [];

	const key = (name: string) =>
		prefix ? `${prefix}${name[0]!.toUpperCase()}${name.slice(1)}` : name;
	const keys = {
		q: key("q"),
		cursor: key("cursor"),
		sort: key("sort"),
		direction: key("direction"),
		pageSize: key("pageSize"),
	};

	const isSortId = (value: string | null): value is SortId =>
		value !== null && Object.hasOwn(sortFields, value);

	const params = $derived(readUrl().searchParams);
	const urlSearch = $derived(params.get(keys.q) ?? "");
	const cursor = $derived(params.get(keys.cursor));
	const pageSize = $derived(parsePageSize(params, keys.pageSize));
	const sortId = $derived.by(() => {
		const requested = params.get(keys.sort);
		return isSortId(requested) ? requested : options.sort.default;
	});
	const direction = $derived.by((): SortDirection => {
		const requested = params.get(keys.direction);
		return requested === "asc" || requested === "desc"
			? requested
			: defaultDirection;
	});
	const filterValue = (name: Filter) => params.get(key(name)) || null;

	// The input shows what was typed while a write is debounced or in flight,
	// and afterwards for as long as the URL agrees with it (the URL holds the
	// trimmed value). Any other URL search, e.g. after Back, wins.
	let typed = $state<string | null>(null);
	let pendingWrites = $state(0);
	let searchTimer: ReturnType<typeof setTimeout> | undefined;
	const draft = $derived(
		typed !== null && (pendingWrites > 0 || typed.trim() === urlSearch)
			? typed
			: urlSearch,
	);

	function href(pathname: string, next: URLSearchParams) {
		const query = next.toString();
		return query ? `${pathname}?${query}` : pathname;
	}

	// Any replace writes a debounced search with it, in the same navigation:
	// a later, separate search write would be built from a URL that may not yet
	// reflect this change, and would undo it.
	function replaceWith(updates: Record<string, string | null>) {
		const url = readUrl();
		const all = { ...updates };
		const flushesSearch = searchTimer !== undefined;
		if (flushesSearch) {
			clearTimeout(searchTimer);
			searchTimer = undefined;
			all[keys.q] = (typed ?? "").trim() || null;
		}
		const next = transitionCursorQuery(url.searchParams, {
			cursorKey: keys.cursor,
			updates: all,
		});
		const navigation = navigate(href(url.pathname, next), { replace: true });
		if (flushesSearch) {
			void Promise.resolve(navigation).finally(() => {
				pendingWrites -= 1;
			});
		}
		return navigation;
	}

	function setSearch(value: string) {
		typed = value;
		if (searchTimer === undefined) pendingWrites += 1;
		else clearTimeout(searchTimer);

		const pathname = readUrl().pathname;
		searchTimer = setTimeout(() => {
			// The user left the table's page; writing would navigate them back.
			if (readUrl().pathname !== pathname) {
				searchTimer = undefined;
				pendingWrites -= 1;
				return;
			}
			void replaceWith({});
		}, debounceMs);
	}

	function submitSearch() {
		if (searchTimer !== undefined) void replaceWith({});
	}

	function setPageSize(next: number) {
		if (!isPageSize(next) || next === pageSize) return;
		void replaceWith({ [keys.pageSize]: next.toString() });
	}

	function goTo(next: string | null | undefined) {
		if (!next) return;
		const url = readUrl();
		const nextParams = transitionCursorQuery(url.searchParams, {
			cursorKey: keys.cursor,
			cursor: next,
		});
		void navigate(href(url.pathname, nextParams), { replace: false });
	}

	const sort = $derived({ id: sortId, direction });
	const sorting: SortingState = $derived([
		{ id: sortId, desc: direction === "desc" },
	]);
	const pagination: PaginationState = $derived({ pageIndex: 0, pageSize });

	const request = $derived.by((): CursorTableRequest<ApiSort, Filter> => {
		const filterEntries = filters.flatMap((name) => {
			const value = filterValue(name);
			return value ? [[name, value] as const] : [];
		});
		const next: CursorTableRequest<ApiSort, Filter> = {
			limit: pageSize,
			sort: sortFields[sortId],
			direction,
			// SAFETY: every key comes from `filters` (so is a `Filter`) and every
			// value is a non-empty string, which is exactly `{ [K in Filter]?: string }`.
			...(Object.fromEntries(filterEntries) as { [K in Filter]?: string }),
		};
		if (cursor) next.cursor = cursor;
		if (urlSearch) next.q = urlSearch;
		return next;
	});

	return {
		get request() {
			return request;
		},
		get sort() {
			return sort;
		},
		get search() {
			return draft;
		},
		setSearch,
		submitSearch,
		filter: filterValue,
		setFilter: (name, value) => {
			void replaceWith({ [key(name)]: value || null });
		},
		get pageSize() {
			return pageSize;
		},
		setPageSize,
		goTo,
		table: {
			state: {
				get sorting() {
					return sorting;
				},
				get pagination() {
					return pagination;
				},
			},
			onSortingChange: (updater) => {
				const [next] = resolve(updater, sorting);
				if (!next || !isSortId(next.id)) return;
				void replaceWith({
					[keys.sort]: next.id,
					[keys.direction]: next.desc ? "desc" : "asc",
				});
			},
			onPaginationChange: (updater) => {
				setPageSize(resolve(updater, pagination).pageSize);
			},
		},
	};
}
