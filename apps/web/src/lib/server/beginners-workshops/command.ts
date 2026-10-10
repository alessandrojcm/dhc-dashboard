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
 */
import { invalid } from "@sveltejs/kit";
import { apiProblem } from "#lib/api-error.js";

export interface BeginnersWorkshopCommandResponse<Data> {
	data?: { data: Data };
	error?: unknown;
}

export type BeginnersWorkshopCommandResult<Data> =
	| { ok: true; data: Data }
	| { ok: false; error: string };

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
	const response = await request;
	if (!response.error && response.data) {
		return { ok: true, data: response.data.data };
	}

	const problem = apiProblem(response.error);
	const detail = problem?.detail ?? translation.fallback;
	const issues = (problem?.fields ?? []).flatMap(({ field, messages }) => {
		const path = translation.formPath(field);
		return path ? messages.map((message) => ({ message, path })) : [];
	});

	if (issues.length === 0) return { ok: false, error: detail };
	invalid(...issues);
}

/** Splits a dotted Phoenix field into a form path (`workshops.1.date` → `["workshops", 1, "date"]`). */
export function dottedPath(field: string): FormPath {
	return field
		.split(".")
		.map((segment) => (/^\d+$/.test(segment) ? Number(segment) : segment));
}
