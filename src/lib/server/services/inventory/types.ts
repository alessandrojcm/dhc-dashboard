/**
 * Type definitions for the inventory domain
 *
 * This module contains type definitions specific to the inventory service layer,
 * including input/output types for service methods.
 */

import type { InventoryCategory, InventoryContainer } from '$lib/types';

// Re-export commonly used types from lib/types
export type {
	InventoryAttributes,
	InventoryAttributeDefinition,
	InventoryCategory,
	InventoryContainer,
	InventoryItem,
	InventoryItemWithRelations,
	InventoryHistoryWithRelations
} from '$lib/types';

// Container types
export type ContainerWithItemCount = InventoryContainer & {
	item_count: number;
};

// Category types
export type CategoryWithItemCount = InventoryCategory & {
	item_count: number;
};

// Item types
export type ItemFilters = {
	search?: string;
	categoryId?: string;
	containerId?: string;
	outForMaintenance?: boolean;
	page?: number;
	limit?: number;
};

export type ItemMovement = {
	itemId: string;
	fromContainerId: string | null;
	toContainerId: string;
	notes?: string;
	changedBy: string;
};

// History types - matches database enum
export type HistoryAction = 'created' | 'updated' | 'moved' | 'maintenance_out' | 'maintenance_in';

export type HistoryRecord = {
	id: string;
	item_id: string;
	action: HistoryAction;
	old_container_id: string | null;
	new_container_id: string | null;
	notes: string | null;
	changed_by: string;
	created_at: string;
};
