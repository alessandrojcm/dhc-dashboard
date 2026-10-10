/**
 * The shared shape of a remote-form command's Phoenix translation, behind
 * `inventoryCommand` and `beginnersWorkshopCommand`.
 *
 * A success answers `{ ok: true, data }`. A rejection is read once with
 * `apiProblem`; the caller attributes its `fields` to form issues. With no
 * attributable issue the command answers `{ ok: false, error }` with the
 * problem `detail` (or the fallback); otherwise the issues are thrown through
 * `invalid`, with the `detail` beside them when the caller reports a field it
 * could not show.
 */
import { invalid } from "@sveltejs/kit";
import { type ApiFieldMessages, apiProblem } from "#lib/api-error.js";

export interface CommandResponse<Data> {
	data?: { data: Data };
	error?: unknown;
}

export type CommandResult<Data> =
	| { ok: true; data: Data }
	| { ok: false; error: string };

export type CommandIssue = Exclude<Parameters<typeof invalid>[number], string>;

export interface FieldAttribution {
	issues: CommandIssue[];
	/** A field Phoenix named that no control shows: keep `detail` visible. */
	unattributed: boolean;
}

export async function commandResult<Data>(
	request: Promise<CommandResponse<Data>>,
	fallback: string,
	attribute: (
		fields: ApiFieldMessages[],
	) => FieldAttribution | Promise<FieldAttribution>,
): Promise<CommandResult<Data>> {
	const response = await request;
	if (!response.error && response.data) {
		return { ok: true, data: response.data.data };
	}

	const problem = apiProblem(response.error);
	const detail = problem?.detail ?? fallback;
	const { issues, unattributed } = await attribute(problem?.fields ?? []);

	if (issues.length === 0) return { ok: false, error: detail };
	if (unattributed) invalid(...issues, detail);
	invalid(...issues);
}
