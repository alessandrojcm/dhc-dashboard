import * as Sentry from "@sentry/sveltekit";
import { dev } from "$app/environment";

export type LogContextValue =
	| string
	| number
	| boolean
	| null
	| undefined
	| LogContextValue[]
	| { [key: string]: LogContextValue };

export type LogContext = Record<string, LogContextValue>;

/**
 * Logger interface for service-layer logging
 * Services accept an optional logger dependency that defaults to console if not provided
 */
export interface Logger {
	/**
	 * Log informational messages
	 */
	info(message: string, context?: LogContext): void;

	/**
	 * Log error messages
	 */
	error(message: string, context?: LogContext): void;

	/**
	 * Log warning messages
	 */
	warn(message: string, context?: LogContext): void;

	/**
	 * Log debug messages
	 */
	debug(message: string, context?: LogContext): void;
}

/**
 * Sentry-integrated logger implementation
 * Logs errors and warnings to Sentry while also logging to console
 */
export const sentryLogger: Logger = {
	info(message: string, context?: LogContext) {
		Sentry.logger.info(message, context);
	},

	error(message: string, context?: LogContext) {
		Sentry.captureException(new Error(message), { extra: context });
	},

	warn(message: string, context?: LogContext) {
		Sentry.logger.warn(message, { level: "warning", extra: context });
	},

	debug(message: string, context?: LogContext) {
		Sentry.logger.debug(message, { level: "warning", extra: context });
	},
};

/**
 * Default console logger (no external dependencies)
 * Useful for testing and development
 */
export const consoleLogger: Logger = {
	info(message: string, context?: LogContext) {
		console.info(message, context);
	},

	error(message: string, context?: LogContext) {
		console.error(message, context);
	},

	warn(message: string, context?: LogContext) {
		console.warn(message, context);
	},

	debug(message: string, context?: LogContext) {
		console.debug(message, context);
	},
};

export default dev ? consoleLogger : sentryLogger;
