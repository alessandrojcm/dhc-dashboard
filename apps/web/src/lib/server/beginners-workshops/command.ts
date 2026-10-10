/**
 * ALE-378: the one translation from a Beginners' Workshop command's Phoenix
 * response to a remote-form result.
 *
 * Phoenix names the field a refusal is about (`DhcWeb.BeginnersWorkshopsHTTP`),
 * dotted for a workshop in a Schedule batch (`workshops.1.contactFromDate`).
 * `formPath` maps that public name onto the form's own field path; each
 * mapped field becomes an issue thrown through `invalid`, so it lands under
 * the right control. Anything else answers `{ ok: false, error }` with the
 * problem `detail`, or the command's fallback.
 *
 * Request-free: the `.remote.ts` file authorizes and makes the generated call.
 * The success / `invalid` plumbing is `commandResult`, shared with
 * `inventoryCommand`.
 */
import {
	type CommandResponse,
	type CommandResult,
	commandResult,
} from "#lib/server/api/command-result.js";

export type BeginnersWorkshopCommandResponse<Data> = CommandResponse<Data>;
export type BeginnersWorkshopCommandResult<Data> = CommandResult<Data>;

/** A form field path: object keys and array indexes. */
export type FormPath = readonly (string | number)[];

export interface BeginnersWorkshopCommandTranslation {
	/** Form-level message when Phoenix sends no `detail`. */
	fallback: string;
	/** The form path for a Phoenix field, or `undefined` when no control shows it. */
	formPath: (field: string) => FormPath | undefined;
}

export async function beginnersWorkshopCommand<Data>(
	request: Promise<BeginnersWorkshopCommandResponse<Data>>,
	translation: BeginnersWorkshopCommandTranslation,
): Promise<BeginnersWorkshopCommandResult<Data>> {
	// A field no control shows is dropped; the mapped ones carry the refusal.
	return commandResult(request, translation.fallback, (fields) => ({
		issues: fields.flatMap(({ field, messages }) => {
			const path = translation.formPath(field);
			return path ? messages.map((message) => ({ message, path })) : [];
		}),
		unattributed: false,
	}));
}

/** Splits a dotted Phoenix field into a form path (`workshops.1.date` → `["workshops", 1, "date"]`). */
export function dottedPath(field: string): FormPath {
	return field
		.split(".")
		.map((segment) => (/^\d+$/.test(segment) ? Number(segment) : segment));
}
