export const PAGE_SIZE_OPTIONS = [10, 25, 50, 100] as const;

export type PageSize = (typeof PAGE_SIZE_OPTIONS)[number];

const DEFAULT_PAGE_SIZE: PageSize = 10;

export function isPageSize(value: number): value is PageSize {
	return PAGE_SIZE_OPTIONS.some((pageSize) => pageSize === value);
}

export function parsePageSize(
	searchParams: URLSearchParams,
	pageSizeKey: string,
): PageSize {
	const requestedPageSize = Number(searchParams.get(pageSizeKey));
	return isPageSize(requestedPageSize) ? requestedPageSize : DEFAULT_PAGE_SIZE;
}

type CursorAdvance = {
	cursorKey: string;
	cursor: string;
};

type IncompatibleQueryChange = {
	cursorKey: string;
	updates: Readonly<Record<string, string | null>>;
};

export function transitionCursorQuery(
	searchParams: URLSearchParams,
	transition: CursorAdvance | IncompatibleQueryChange,
): URLSearchParams {
	const next = new URLSearchParams(searchParams);

	if ("cursor" in transition) {
		next.set(transition.cursorKey, transition.cursor);
		return next;
	}

	for (const [key, value] of Object.entries(transition.updates)) {
		if (value === null) next.delete(key);
		else next.set(key, value);
	}

	next.delete(transition.cursorKey);
	return next;
}
