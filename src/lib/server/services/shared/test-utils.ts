import { vi, type MockedFunction } from "vitest";
import type { Logger } from "./logger";
import type { Session } from "@supabase/supabase-js";
import type { Kysely } from "kysely";
import type Stripe from "stripe";
import type { KyselyDatabase } from "$lib/types";

/**
 * Creates a mock logger for testing
 * All methods are vi.fn() that can be asserted against
 */
export function createMockLogger(): Logger {
	return {
		info: vi.fn(),
		error: vi.fn(),
		warn: vi.fn(),
		debug: vi.fn(),
	};
}

/**
 * Creates a mock Supabase session for testing
 */
export function createMockSession(overrides?: Partial<Session>): Session {
	return {
		access_token: "mock-access-token",
		refresh_token: "mock-refresh-token",
		expires_in: 3600,
		expires_at: Date.now() + 3600000,
		token_type: "bearer",
		user: {
			id: "mock-user-id",
			aud: "authenticated",
			role: "authenticated",
			email: "test@example.com",
			email_confirmed_at: new Date().toISOString(),
			phone: "",
			confirmed_at: new Date().toISOString(),
			last_sign_in_at: new Date().toISOString(),
			app_metadata: {},
			user_metadata: {},
			identities: [],
			created_at: new Date().toISOString(),
			updated_at: new Date().toISOString(),
		},
		...overrides,
	};
}

/**
 * Type for a mocked Kysely instance
 * This is a placeholder - you'll need to implement proper mocking based on your testing needs
 */
export type MockedKysely = {
	selectFrom: MockedFunction<Kysely<KyselyDatabase>["selectFrom"]>;
	insertInto: MockedFunction<Kysely<KyselyDatabase>["insertInto"]>;
	updateTable: MockedFunction<Kysely<KyselyDatabase>["updateTable"]>;
	deleteFrom: MockedFunction<Kysely<KyselyDatabase>["deleteFrom"]>;
	transaction: MockedFunction<Kysely<KyselyDatabase>["transaction"]>;
	// Add more methods as needed
};

/**
 * Creates a basic mock Kysely instance for testing
 * For more complex testing, consider using a real database or a more sophisticated mock
 */
export function createMockKysely(): MockedKysely {
	return {
		selectFrom: vi.fn(),
		insertInto: vi.fn(),
		updateTable: vi.fn(),
		deleteFrom: vi.fn(),
		transaction: vi.fn(),
	} as MockedKysely;
}

/**
 * Creates a mock Stripe client for testing
 * Includes commonly used Stripe methods
 */
export function createMockStripe(): Partial<Stripe> {
	return {
		customers: {
			create: vi.fn(),
			update: vi.fn(),
			retrieve: vi.fn(),
			del: vi.fn(),
			list: vi.fn(),
		},
		subscriptions: {
			create: vi.fn(),
			update: vi.fn(),
			retrieve: vi.fn(),
			cancel: vi.fn(),
			list: vi.fn(),
		},
		// Add more Stripe resources as needed
	};
}

/**
 * Example test data generators
 */
export const testData = {
	/**
	 * Generate a unique email for testing
	 */
	uniqueEmail: (prefix = "test") => {
		const timestamp = Date.now();
		const random = Math.random().toString(36).substring(2, 15);
		return `${prefix}-${timestamp}-${random}@example.com`;
	},

	/**
	 * Generate a unique ID for testing
	 */
	uniqueId: () => {
		return `test-${Date.now()}-${Math.random().toString(36).substring(2, 15)}`;
	},
};
