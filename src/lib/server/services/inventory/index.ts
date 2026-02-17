/**
 * Inventory Services
 *
 * This module provides services for managing the inventory domain:
 * - Item management (CRUD, movement, maintenance)
 * - Container management (CRUD, hierarchical relationships)
 * - Category management (CRUD, attribute schemas)
 * - History tracking (item movements, changes)
 *
 * ## Usage Example
 *
 * ```typescript
 * // data.remote.ts
 * import { form, getRequestEvent } from '$app/server';
 * import { createItemService, ItemCreateSchema } from '$lib/server/services/inventory';
 *
 * export const createItem = form(ItemCreateSchema, async (data) => {
 *   const event = getRequestEvent();
 *   const { session } = await event.locals.safeGetSession();
 *
 *   const itemService = createItemService(event.platform!, session!);
 *   const item = await itemService.create(data);
 *
 *   return { success: true, item };
 * });
 * ```
 */

import { getKyselyClient } from "../shared";
import { sentryLogger } from "../shared/logger";
import type { Logger, Session } from "../shared";
import { ItemService } from "./item.service";
import { ContainerService } from "./container.service";
import { CategoryService } from "./category.service";
import { HistoryService } from "./history.service";

// Service exports
export { ItemService } from "./item.service";
export { ContainerService } from "./container.service";
export { CategoryService } from "./category.service";
export { HistoryService } from "./history.service";

// Schema exports
export {
	ItemCreateSchema,
	ItemUpdateSchema,
	type ItemCreateInput,
	type ItemUpdateInput,
} from "./item.service";
export {
	ContainerCreateSchema,
	ContainerUpdateSchema,
	type ContainerCreateInput,
	type ContainerUpdateInput,
} from "./container.service";
export {
	CategoryCreateSchema,
	CategoryUpdateSchema,
	type CategoryCreateInput,
	type CategoryUpdateInput,
} from "./category.service";

// Type exports
export type {
	InventoryAttributes,
	InventoryAttributeDefinition,
	InventoryCategory,
	InventoryContainer,
	InventoryItem,
	InventoryItemWithRelations,
	InventoryHistoryWithRelations,
	ItemFilters,
	ContainerWithItemCount,
	CategoryWithItemCount,
	HistoryAction,
} from "./types";

/**
 * Create an ItemService instance
 *
 * @param platform - App platform (contains Hyperdrive connection)
 * @param session - User session (for RLS)
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns ItemService instance
 */
export function createItemService(
	platform: App.Platform,
	session: Session,
	logger?: Logger,
): ItemService {
	return new ItemService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		logger ?? sentryLogger,
	);
}

/**
 * Create a ContainerService instance
 *
 * @param platform - App platform (contains Hyperdrive connection)
 * @param session - User session (for RLS)
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns ContainerService instance
 */
export function createContainerService(
	platform: App.Platform,
	session: Session,
	logger?: Logger,
): ContainerService {
	return new ContainerService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		logger ?? sentryLogger,
	);
}

/**
 * Create a CategoryService instance
 *
 * @param platform - App platform (contains Hyperdrive connection)
 * @param session - User session (for RLS)
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns CategoryService instance
 */
export function createCategoryService(
	platform: App.Platform,
	session: Session,
	logger?: Logger,
): CategoryService {
	return new CategoryService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		logger ?? sentryLogger,
	);
}

/**
 * Create a HistoryService instance
 *
 * @param platform - App platform (contains Hyperdrive connection)
 * @param session - User session (for RLS)
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns HistoryService instance
 */
export function createHistoryService(
	platform: App.Platform,
	session: Session,
	logger?: Logger,
): HistoryService {
	return new HistoryService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		logger ?? sentryLogger,
	);
}

/**
 * Create all inventory services at once (useful for complex operations)
 *
 * @param platform - App platform (contains Hyperdrive connection)
 * @param session - User session (for RLS)
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns Object containing all inventory services
 */
export function createInventoryServices(
	platform: App.Platform,
	session: Session,
	logger?: Logger,
) {
	const loggerInstance = logger ?? sentryLogger;
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);

	return {
		itemService: new ItemService(kysely, session, loggerInstance),
		containerService: new ContainerService(kysely, session, loggerInstance),
		categoryService: new CategoryService(kysely, session, loggerInstance),
		historyService: new HistoryService(kysely, session, loggerInstance),
	};
}
