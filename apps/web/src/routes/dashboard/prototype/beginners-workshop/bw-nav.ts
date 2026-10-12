// PROTOTYPE — throwaway (ALE-372). Screen navigation inside the one prototype route.
import { goto } from "$app/navigation";
import { page } from "$app/state";

export type Screen =
	| "workshops"
	| "console"
	| "door"
	| "templates"
	| "invitable";

export function go(screen: Screen, workshopId?: string) {
	const url = new URL(page.url.href);
	url.searchParams.set("screen", screen);
	if (workshopId) url.searchParams.set("w", workshopId);
	if (screen !== (page.url.searchParams.get("screen") ?? "workshops"))
		url.searchParams.delete("variant");
	void goto(`${url.pathname}${url.search}`);
}
