/**
 * Logger interface for service-layer logging
 * Services accept an optional logger dependency that defaults to console if not provided
 */
export interface Logger {
	/**
	 * Log informational messages
	 */
	info(message: string, context?: Record<string, unknown>): void;

	/**
	 * Log error messages
	 */
	error(message: string, context?: Record<string, unknown>): void;

	/**
	 * Log warning messages
	 */
	warn(message: string, context?: Record<string, unknown>): void;

	/**
	 * Log debug messages
	 */
	debug(message: string, context?: Record<string, unknown>): void;
}

/**
 * Sentry-integrated logger implementation
 * Logs errors and warnings to Sentry while also logging to console
 */
export const sentryLogger: Logger = {
	info(message: string, context?: Record<string, unknown>) {
		console.info(message, context);
	},

	error(message: string, context?: Record<string, unknown>) {
		// Only import Sentry when needed to avoid server-side bundling issues
		import("@sentry/sveltekit").then((Sentry) => {
			Sentry.captureException(new Error(message), { extra: context });
		});
		console.error(message, context);
	},

	warn(message: string, context?: Record<string, unknown>) {
		// Only import Sentry when needed to avoid server-side bundling issues
		import("@sentry/sveltekit").then((Sentry) => {
			Sentry.captureMessage(message, { level: "warning", extra: context });
		});
		console.warn(message, context);
	},

	debug(message: string, context?: Record<string, unknown>) {
		console.debug(message, context);
	},
};

/**
 * Default console logger (no external dependencies)
 * Useful for testing and development
 */
export const consoleLogger: Logger = {
	info(message: string, context?: Record<string, unknown>) {
		console.info(message, context);
	},

	error(message: string, context?: Record<string, unknown>) {
		console.error(message, context);
	},

	warn(message: string, context?: Record<string, unknown>) {
		console.warn(message, context);
	},

	debug(message: string, context?: Record<string, unknown>) {
		console.debug(message, context);
	},
};
