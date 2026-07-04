import { error } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	inventoryCategoriesIndex,
	inventoryContainersIndex,
	inventoryItemsHistory,
	inventoryItemsShow,
} from "@dhc/api-client";
import type {
	InventoryAttributeDefinition,
	InventoryAttributes,
} from "$lib/types";
import type { PageServerLoad } from "./$types";

type ApiCategory = {
	id: string;
	name: string;
	description?: string | null;
	availableAttributes?: Array<Record<string, unknown>>;
};

function toLegacyCategory(c: ApiCategory) {
	return {
		id: c.id,
		name: c.name,
		description: c.description ?? null,
		available_attributes: (c.availableAttributes ?? []).map((attr) => {
			const { defaultValue, ...rest } = attr;
			return {
				...rest,
				...(defaultValue !== undefined ? { default_value: defaultValue } : {}),
			};
		}),
	};
}

function toLegacyContainer(c: {
	id: string;
	name: string;
	description?: string | null;
	parentContainerId?: string | null;
}) {
	return {
		id: c.id,
		name: c.name,
		description: c.description ?? null,
		parent_container_id: c.parentContainerId ?? null,
		created_by: "",
		created_at: null,
		updated_at: null,
	};
}

export const load: PageServerLoad = async ({ params, locals }) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const options = apiClientOptions(session);

	const [itemResponse, historyResponse, categoriesResponse, containersResponse] =
		await Promise.all([
			inventoryItemsShow({ ...options, path: { id: params.id } }),
			inventoryItemsHistory({ ...options, path: { id: params.id }, query: { limit: 20 } }),
			inventoryCategoriesIndex(options),
			inventoryContainersIndex(options),
		]);

	if (itemResponse.error) {
		throw error(404, itemResponse.error.errors?.detail ?? "Item not found");
	}
	if (historyResponse.error) {
		throw error(404, historyResponse.error.errors?.detail ?? "Item not found");
	}
	if (categoriesResponse.error) throw new Error("Failed to load categories");
	if (containersResponse.error) throw new Error("Failed to load containers");

	const categories = categoriesResponse.data.data.categories.map(toLegacyCategory);
	const containers = containersResponse.data.data.containers.map(toLegacyContainer);
	const apiItem = itemResponse.data.data;
	const fullCategory = categories.find((c) => c.id === apiItem.categoryId);

	const item = {
		id: apiItem.id,
		container_id: apiItem.containerId,
		category_id: apiItem.categoryId,
		quantity: apiItem.quantity,
		notes: apiItem.notes ?? null,
		out_for_maintenance: apiItem.outForMaintenance,
		attributes: (apiItem.attributes ?? {}) as InventoryAttributes,
		photo_url: apiItem.photoUrl ?? null,
		created_at: apiItem.createdAt,
		updated_at: apiItem.updatedAt,
		created_by: apiItem.createdBy ?? null,
		updated_by: apiItem.updatedBy ?? null,
		container: apiItem.container
			? {
				id: apiItem.container.id,
				name: apiItem.container.name,
				parent_container_id: apiItem.container.parentContainerId ?? null,
			}
			: null,
		category: fullCategory ??
			(apiItem.category
				? {
					id: apiItem.category.id,
					name: apiItem.category.name,
					available_attributes: [],
				}
				: null),
	};

	const history = historyResponse.data.data.history.map((h) => ({
		id: h.id,
		item_id: h.itemId,
		action: h.action,
		old_container_id: h.oldContainerId ?? null,
		new_container_id: h.newContainerId ?? null,
		notes: h.notes ?? null,
		changed_by: h.changedBy ?? null,
		created_at: h.createdAt,
		old_container: h.oldContainer,
		new_container: h.newContainer,
	}));

	const initialAttributes: InventoryAttributes = {};
	const existingAttributes = (item.attributes as InventoryAttributes) || {};

	if (item.category?.available_attributes) {
		const availableAttributes = item.category
			.available_attributes as InventoryAttributeDefinition[];
		availableAttributes.forEach((attr) => {
			initialAttributes[attr.name] =
				existingAttributes[attr.name] ?? attr.default_value ?? undefined;
		});
	}

	return {
		item,
		history,
		categories,
		containers,
		initialFormData: {
			container_id: item.container?.id ?? "",
			category_id: item.category?.id ?? "",
			quantity: item.quantity,
			notes: item.notes || "",
			out_for_maintenance: item.out_for_maintenance || false,
			attributes: initialAttributes,
		},
	};
};
