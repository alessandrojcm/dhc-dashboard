/**
 * The Items page's management drafts (ALE-416, ALE-451): what each management
 * form holds, its dirty state, and how a command's answer rebases them.
 *
 * Pure: the workbench controller keeps the live drafts in runes state (the
 * page binds to them) and hands plain snapshots to these functions. The drafts
 * are independent of one another and of the workbench machine's states; the
 * machine only decides *when* a command's answer rebases them.
 */
import type { InventoryOperatorItem } from "@dhc/api-client";
import {
	draftFromItem,
	type PropertyDraft,
	sameDraft,
} from "#lib/inventory/property-values.js";

export type ItemFields = {
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
export type ItemDrafts = { item: InventoryOperatorItem; fields: ItemFields };

/** The management forms an Item command's success answers for. */
export type DraftGroup =
	| "details"
	| "placement"
	| "category"
	| "maintenance"
	| "archive";

/** Fresh drafts, started from `item`. */
export function itemDrafts(item: InventoryOperatorItem): ItemDrafts {
	return {
		item,
		fields: {
			notes: item.notes ?? "",
			values: draftFromItem(item),
			containerId: item.containerId ?? "",
			categoryId: item.categoryId,
			categoryValues: draftFromItem(item),
			maintenanceReason: "",
			maintenanceEndNote: "",
			archiveReason: "",
		},
	};
}

/** Whether each item-backed form's draft differs from the item it started from. */
export function dirtyOf({ item, fields }: ItemDrafts) {
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
}

/**
 * The drafts once a command answered with `item`. The submitting form (`own`)
 * starts again from the answer. Another form keeps what the operator typed but
 * has not saved yet, so a slow command cannot wipe an edit made while it ran:
 * the maintenance and archive notes always, and an item-backed draft while it
 * is unsaved and the answer left the facts it edits unchanged. Every other
 * draft follows the answer.
 */
export function rebasedDrafts(
	current: ItemDrafts | undefined,
	item: InventoryOperatorItem,
	own: DraftGroup,
): ItemDrafts {
	const next = itemDrafts(item);
	if (!current || current.item.id !== item.id) return next;
	const before = current.item;
	const sameValues = sameDraft(draftFromItem(before), draftFromItem(item));
	const dirty = dirtyOf(current);
	const keeps = (group: keyof typeof dirty, unchanged: boolean) =>
		group !== own && dirty[group] && unchanged;
	const { fields } = current;

	if (
		keeps("details", (before.notes ?? "") === (item.notes ?? "") && sameValues)
	) {
		next.fields.notes = fields.notes;
		next.fields.values = fields.values;
	}
	if (keeps("placement", before.containerId === item.containerId)) {
		next.fields.containerId = fields.containerId;
	}
	if (keeps("category", before.categoryId === item.categoryId && sameValues)) {
		next.fields.categoryId = fields.categoryId;
		next.fields.categoryValues = fields.categoryValues;
	}
	if (own !== "maintenance") {
		next.fields.maintenanceReason = fields.maintenanceReason;
		next.fields.maintenanceEndNote = fields.maintenanceEndNote;
	}
	if (own !== "archive") next.fields.archiveReason = fields.archiveReason;
	return next;
}
