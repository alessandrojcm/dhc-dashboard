/**
 * Optimistic cache predictions for the Training Announcement commands whose
 * result the browser can know before Phoenix answers: the four lifecycle
 * commands on the rail and removing a Suppression or Override.
 *
 * These are predictions, never decisions. Phoenix still refuses what it
 * refuses (deleting an announcement that has posted, editing a retired one),
 * the caller rolls the cache back on error, and every command refetches once
 * it settles so the server's row replaces the guess.
 */
import type { TrainingAnnouncement } from "@dhc/api-client";
import type { QueryKey } from "@tanstack/svelte-query";

export type LifecycleCommand = "disable" | "enable" | "retire" | "delete";

/**
 * The rows one `list` cache should show once `command` succeeds for `id`.
 * A retired announcement leaves a list that excludes retired rows — the same
 * filter Phoenix's `list` applies — and stays, marked retired, in one that
 * includes them.
 */
export function applyLifecycle(
	rows: TrainingAnnouncement[],
	id: string,
	command: LifecycleCommand,
	includeRetired: boolean,
): TrainingAnnouncement[] {
	switch (command) {
		case "delete":
			return withoutRow(rows, id);
		case "retire":
			return includeRetired
				? rows.map((row) => (row.id === id ? { ...row, retired: true } : row))
				: withoutRow(rows, id);
		case "disable":
		case "enable": {
			const enabled = command === "enable";
			return rows.map((row) => (row.id === id ? { ...row, enabled } : row));
		}
	}
}

/** The list without the row `id`, for any id-keyed read. */
export function withoutRow<T extends { id: string }>(
	rows: T[],
	id: string,
): T[] {
	return rows.filter((row) => row.id !== id);
}

/**
 * Whether a cached `trainingAnnouncementsList` query asked for retired rows.
 * The generated key carries the request's `query` in its first element.
 */
export function listIncludesRetired(key: QueryKey): boolean {
	const [params] = key;
	if (typeof params !== "object" || params === null || !("query" in params))
		return false;
	const { query } = params;
	return (
		typeof query === "object" &&
		query !== null &&
		"includeRetired" in query &&
		query.includeRetired === true
	);
}
