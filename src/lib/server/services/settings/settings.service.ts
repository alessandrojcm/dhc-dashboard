/**
 * Settings Service
 *
 * Handles system settings management including reading, updating,
 * and toggling boolean settings.
 */

import * as v from "valibot";
import {
    executeWithRLS,
    type Kysely,
    type KyselyDatabase,
    type Logger,
    type Session,
    type Transaction,
} from "../shared";
import type {Setting, SettingKey, SettingUpdate} from "./types";

/**
 * Validation schema for insurance form link setting
 */
export const InsuranceFormLinkSchema = v.object({
	insuranceFormLink: v.pipe(
		v.string(),
		v.nonEmpty("Please enter the HEMA Insurance Form link."),
		v.url("Please enter a valid URL."),
	),
});

export type InsuranceFormLinkInput = v.InferOutput<
	typeof InsuranceFormLinkSchema
>;

/**
 * Service for managing system settings
 */
export class SettingsService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger,
	) {
		this.logger = logger ?? console;
	}

	/**
	 * Find a setting by its key
	 *
	 * @param key - The setting key to find
	 * @returns The setting or null if not found
	 */
	async findByKey(key: SettingKey): Promise<Setting | null> {
		this.logger.debug("Finding setting by key", { key });

		try {
			const setting = await this.kysely
				.selectFrom("settings")
				.selectAll()
				.where("key", "=", key)
				.executeTakeFirst();

			return setting ?? null;
		} catch (error) {
			this.logger.error("Failed to find setting by key", { key, error });
			throw new Error("Failed to find setting", {
				cause: { key, originalError: error },
			});
		}
	}

	/**
	 * Find multiple settings by their keys
	 *
	 * @param keys - Array of setting keys to find
	 * @returns Array of found settings
	 */
	async findMany(keys?: SettingKey[]): Promise<Setting[]> {
		this.logger.debug("Finding multiple settings", { keys });

		try {
			let query = this.kysely.selectFrom("settings").selectAll();

			if (keys && keys.length > 0) {
				query = query.where("key", "in", keys);
			}

            return query.execute();
		} catch (error) {
			this.logger.error("Failed to find settings", { keys, error });
			throw new Error("Failed to find settings", {
				cause: { keys, originalError: error },
			});
		}
	}

	/**
	 * Update a setting by its key
	 *
	 * @param key - The setting key to update
	 * @param update - The values to update
	 * @returns The updated setting
	 */
	async update(key: SettingKey, update: SettingUpdate): Promise<Setting> {
		this.logger.info("Updating setting", { key, update });

		try {
			return await executeWithRLS(
				this.kysely,
				{ claims: this.session },
				async (trx) => {
					return this._update(trx, key, update);
				},
			);
		} catch (error) {
			this.logger.error("Failed to update setting", { key, error });
			throw new Error("Failed to update setting", {
				cause: { key, originalError: error },
			});
		}
	}

	/**
	 * Update insurance form link setting (convenience method)
	 *
	 * @param url - The new insurance form link URL
	 * @returns The updated setting
	 */
	async updateInsuranceFormLink(url: string): Promise<Setting> {
		this.logger.info("Updating insurance form link", { url });

		return this.update("hema_insurance_form_link", { value: url });
	}

	/**
	 * Toggle a boolean setting
	 *
	 * @param key - The setting key to toggle
	 * @returns The updated setting with the new value
	 */
	async toggle(key: SettingKey): Promise<Setting> {
		this.logger.info("Toggling setting", { key });

		try {
			return await executeWithRLS(
				this.kysely,
				{ claims: this.session },
				async (trx) => {
					// Get current value
					const currentSetting = await trx
						.selectFrom("settings")
						.select("value")
						.where("key", "=", key)
						.executeTakeFirstOrThrow();

					// Toggle the boolean value
					const newValue = currentSetting.value === "true" ? "false" : "true";

					// Update with new value
					return this._update(trx, key, { value: newValue });
				},
			);
		} catch (error) {
			this.logger.error("Failed to toggle setting", { key, error });
			throw new Error("Failed to toggle setting", {
				cause: { key, originalError: error },
			});
		}
	}

	/**
	 * Toggle waitlist open/closed status (convenience method)
	 *
	 * @returns The updated setting with the new value
	 */
	async toggleWaitlist(): Promise<Setting> {
		this.logger.info("Toggling waitlist status");

		return this.toggle("waitlist_open");
	}

	/**
	 * Check if waitlist is currently open
	 *
	 * @returns True if waitlist is open, false otherwise
	 */
	async isWaitlistOpen(): Promise<boolean> {
		this.logger.debug("Checking waitlist status");

		try {
			const setting = await this.findByKey("waitlist_open");
			return setting?.value === "true";
		} catch (error) {
			this.logger.error("Failed to check waitlist status", { error });
			throw new Error("Failed to check waitlist status", {
				cause: { originalError: error },
			});
		}
	}

	/**
	 * Private transactional method for updating a setting
	 * Used for cross-service coordination
	 *
	 * @param trx - Database transaction
	 * @param key - The setting key to update
	 * @param update - The values to update
	 * @returns The updated setting
	 */
	async _update(
		trx: Transaction<KyselyDatabase>,
		key: SettingKey,
		update: SettingUpdate,
	): Promise<Setting> {
		return trx
			.updateTable("settings")
			.set(update)
			.where("key", "=", key)
			.returningAll()
			.executeTakeFirstOrThrow();
	}
}
