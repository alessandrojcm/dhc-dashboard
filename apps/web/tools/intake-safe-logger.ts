import { createLogger, type Logger } from "vite";
import { redactIntakeLinks } from "../src/lib/intake-link-redaction.js";

/** SvelteKit's dev access lines pass through Vite, outside handleError. */
export function intakeSafeLogger(): Logger {
	const logger = createLogger();
	const { info, warn, warnOnce, error } = logger;
	return Object.assign(logger, {
		info: (message, options) => info(redactIntakeLinks(message), options),
		warn: (message, options) => warn(redactIntakeLinks(message), options),
		warnOnce: (message, options) =>
			warnOnce(redactIntakeLinks(message), options),
		error: (message, options) => error(redactIntakeLinks(message), options),
	} satisfies Partial<Logger>);
}
