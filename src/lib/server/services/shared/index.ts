/**
 * Shared utilities and types for all services
 *
 * This module provides:
 * - Logger interface and implementations (Sentry, console)
 * - Common types for service configuration
 * - Re-exported Kysely utilities (executeWithRLS, getKyselyClient)
 * - Re-exported type definitions
 * - Test utilities for mocking services
 */

// Logger exports
export { sentryLogger, consoleLogger } from "./logger";
export type { Logger } from "./logger";

// Kysely utilities
export { getKyselyClient, executeWithRLS, sql } from "$lib/server/kysely";

// Type exports
export type {
	ServiceConfig,
	Kysely,
	Transaction,
	KyselyDatabase,
	Session,
} from "./types";

// Test utilities (for use in tests only)
export {
	createMockLogger,
	createMockSession,
	createMockKysely,
	createMockStripe,
	testData,
} from "./test-utils";
export type { MockedKysely } from "./test-utils";
