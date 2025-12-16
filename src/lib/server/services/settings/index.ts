/**
 * Settings Service Module
 *
 * Public API for the settings domain.
 */

import { getKyselyClient, sentryLogger, type Logger, type Session } from '../shared';
import { SettingsService } from './settings.service';

// Re-export service class
export { SettingsService } from './settings.service';

// Re-export types
export type { Setting, SettingInsert, SettingUpdate, SettingKey, SettingType } from './types';

// Re-export validation schemas
export { InsuranceFormLinkSchema, type InsuranceFormLinkInput } from './settings.service';

/**
 * Factory function to create a SettingsService instance
 *
 * @param platform - SvelteKit platform object
 * @param session - Authenticated user session
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns Configured SettingsService instance
 *
 * @example
 * ```typescript
 * const settingsService = createSettingsService(platform, session);
 * const setting = await settingsService.findByKey('waitlist_open');
 * ```
 */
export function createSettingsService(
	platform: App.Platform,
	session: Session,
	logger?: Logger
): SettingsService {
	return new SettingsService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		logger ?? sentryLogger
	);
}
