/**
 * Resolves the shallow-routed sheet selection.
 *
 * `page.state` wins after `pushState`. A full load of the detail URL has
 * empty state, so the pathname segment is the fallback. `replaceState` back
 * to the list updates `page.url` without rematching params, so the URL — not
 * `page.params` — is the source of truth.
 */
export function sheetSelection(
	pathname: string,
	listPath: string,
	stateValue: string | undefined,
): string | undefined {
	if (stateValue) return stateValue;
	if (pathname === listPath) return undefined;
	const prefix = `${listPath}/`;
	if (!pathname.startsWith(prefix)) return undefined;
	const rest = pathname.slice(prefix.length);
	if (!rest || rest.includes("/")) return undefined;
	return decodeURIComponent(rest);
}

export type ClickModifiers = {
	button: number;
	metaKey?: boolean;
	ctrlKey?: boolean;
	shiftKey?: boolean;
	altKey?: boolean;
};

export function isModifiedClick(event: ClickModifiers): boolean {
	return (
		Boolean(event.metaKey) ||
		Boolean(event.ctrlKey) ||
		Boolean(event.shiftKey) ||
		Boolean(event.altKey) ||
		event.button !== 0
	);
}
