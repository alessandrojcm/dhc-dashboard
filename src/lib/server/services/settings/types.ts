/**
 * Settings Domain Types
 *
 * Type definitions for the settings domain.
 */

import type { Database } from "$lib/../database.types";

/**
 * Setting type from database
 */
export type Setting = Database["public"]["Tables"]["settings"]["Row"];

/**
 * Input for creating a new setting
 */
export type SettingInsert = Database["public"]["Tables"]["settings"]["Insert"];

/**
 * Input for updating an existing setting
 */
export type SettingUpdate = Partial<
	Pick<Setting, "value" | "description" | "type">
>;

/**
 * Known setting keys in the system
 */
export type SettingKey =
	| "waitlist_open"
	| "hema_insurance_form_link"
	| "subscription_max_pause_months"
	| "subscription_min_pause_days";

/**
 * Setting type enum
 */
export type SettingType = Database["public"]["Enums"]["setting_type"];
