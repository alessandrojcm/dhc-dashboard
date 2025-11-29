/**
 * Category Service
 *
 * Handles equipment category operations including:
 * - CRUD operations (create, read, update, delete)
 * - Attribute schema management
 */

import * as v from "valibot";
import { categorySchema } from "$lib/schemas/inventory";
import type {
	Logger,
	Kysely,
	Transaction,
	KyselyDatabase,
	Session,
} from "../shared";
import { executeWithRLS } from "../shared";
import type { InventoryCategory } from "./types";

// Export validation schemas for reuse in forms
export const CategoryCreateSchema = categorySchema;
export const CategoryUpdateSchema = categorySchema;

export type CategoryCreateInput = v.InferOutput<typeof CategoryCreateSchema>;
export type CategoryUpdateInput = v.InferOutput<typeof CategoryUpdateSchema>;

/**
 * Service for managing equipment categories
 */
export class CategoryService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger,
	) {
		this.logger = logger ?? console;
	}

	/**
	 * Create a new category
	 */
	async create(input: CategoryCreateInput): Promise<InventoryCategory> {
		this.logger.info("Creating category", { name: input.name });

		try {
			return await executeWithRLS(
				this.kysely,
				{ claims: this.session },
				async (trx) => {
					return this._create(trx, input);
				},
			);
		} catch (error) {
			this.logger.error("Failed to create category", { error, input });
			throw new Error("Failed to create category", {
				cause: { originalError: error, input },
			});
		}
	}

	/**
	 * Transactional create method
	 */
	async _create(
		trx: Transaction<KyselyDatabase>,
		input: CategoryCreateInput,
	): Promise<InventoryCategory> {
		const result = await trx
			.insertInto("equipment_categories")
			.values({
				name: input.name,
				description: input.description || null,
				available_attributes: input.available_attributes || [],
				created_at: new Date().toISOString(),
				updated_at: new Date().toISOString(),
			})
			.returningAll()
			.execute();

		if (!result || result.length === 0) {
			throw new Error("Failed to create category");
		}

		return result[0] as InventoryCategory;
	}

	/**
	 * Find a category by ID
	 */
	async findById(id: string): Promise<InventoryCategory> {
		this.logger.info("Finding category by ID", { categoryId: id });

		try {
			return await executeWithRLS(
				this.kysely,
				{ claims: this.session },
				async (trx) => {
					return this._findById(trx, id);
				},
			);
		} catch (error) {
			this.logger.error("Failed to find category", {
				error,
				categoryId: id,
			});
			throw new Error("Category not found", {
				cause: { categoryId: id, originalError: error },
			});
		}
	}

	/**
	 * Transactional findById method
	 */
	async _findById(
		trx: Transaction<KyselyDatabase>,
		id: string,
	): Promise<InventoryCategory> {
		const category = await trx
			.selectFrom("equipment_categories")
			.selectAll()
			.where("id", "=", id)
			.executeTakeFirst();

		if (!category) {
			throw new Error("Category not found", {
				cause: { categoryId: id, context: "CategoryService._findById" },
			});
		}

		return category as InventoryCategory;
	}

	/**
	 * Find all categories
	 */
	async findMany(): Promise<InventoryCategory[]> {
		this.logger.info("Finding all categories");

		try {
			return await executeWithRLS(
				this.kysely,
				{ claims: this.session },
				async (trx) => {
					const categories = await trx
						.selectFrom("equipment_categories")
						.selectAll()
						.orderBy("name")
						.execute();

					return categories as InventoryCategory[];
				},
			);
		} catch (error) {
			this.logger.error("Failed to find categories", { error });
			throw new Error("Failed to find categories", {
				cause: { originalError: error },
			});
		}
	}

	/**
	 * Update a category
	 */
	async update(
		id: string,
		input: CategoryUpdateInput,
	): Promise<InventoryCategory> {
		this.logger.info("Updating category", { categoryId: id, updates: input });

		try {
			return await executeWithRLS(
				this.kysely,
				{ claims: this.session },
				async (trx) => {
					return this._update(trx, id, input);
				},
			);
		} catch (error) {
			this.logger.error("Failed to update category", {
				error,
				categoryId: id,
				input,
			});
			throw new Error("Failed to update category", {
				cause: { categoryId: id, originalError: error },
			});
		}
	}

	/**
	 * Transactional update method
	 */
	async _update(
		trx: Transaction<KyselyDatabase>,
		id: string,
		input: CategoryUpdateInput,
	): Promise<InventoryCategory> {
		await trx
			.updateTable("equipment_categories")
			.set({
				name: input.name,
				description: input.description || null,
				available_attributes: input.available_attributes || [],
				updated_at: new Date().toISOString(),
			})
			.where("id", "=", id)
			.execute();

		return this._findById(trx, id);
	}

	/**
	 * Delete a category
	 */
	async delete(id: string): Promise<void> {
		this.logger.info("Deleting category", { categoryId: id });

		try {
			await executeWithRLS(
				this.kysely,
				{ claims: this.session },
				async (trx) => {
					await trx
						.deleteFrom("equipment_categories")
						.where("id", "=", id)
						.execute();
				},
			);
		} catch (error) {
			this.logger.error("Failed to delete category", {
				error,
				categoryId: id,
			});
			throw new Error("Failed to delete category", {
				cause: { categoryId: id, originalError: error },
			});
		}
	}

	/**
	 * Get category with item count
	 */
	async getWithItemCount(
		id: string,
	): Promise<InventoryCategory & { itemCount: number }> {
		this.logger.info("Getting category with item count", { categoryId: id });

		try {
			return await executeWithRLS(
				this.kysely,
				{ claims: this.session },
				async (trx) => {
					const category = await this._findById(trx, id);

					const itemCount = await trx
						.selectFrom("inventory_items")
						.select((eb) => eb.fn.count("id").as("count"))
						.where("category_id", "=", id)
						.executeTakeFirst();

					return {
						...category,
						itemCount: Number(itemCount?.count || 0),
					};
				},
			);
		} catch (error) {
			this.logger.error("Failed to get category with item count", {
				error,
				categoryId: id,
			});
			throw new Error("Failed to get category with item count", {
				cause: { categoryId: id, originalError: error },
			});
		}
	}
}
