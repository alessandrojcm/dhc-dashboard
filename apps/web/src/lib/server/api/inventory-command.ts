/**
 * ALE-357: the one translation from an inventory quartermaster command's
 * Phoenix response to a remote-form result.
 *
 * A rejection whose `fields` name a form field becomes that field's issue
 * (thrown through `invalid`, so it reaches `fields.x.issues()` and
 * `aria-invalid`). Anything else answers `{ ok: false, error }` with the
 * problem `detail`, or the command's fallback.
 *
 * It takes no request event: the `.remote.ts` file authorizes, makes the
 * generated call, and passes in the pending response and its `issue` builder.
 */
import * as Sentry from "@sentry/sveltekit";
import type { ApiFieldMessages } from "#lib/api-error.js";
import {
	type CommandIssue as Issue,
	type CommandResponse,
	type CommandResult,
	commandResult,
	type FieldAttribution,
} from "#lib/server/api/command-result.js";

export type InventoryCommandResponse<Data> = CommandResponse<Data>;
export type InventoryCommandResult<Data> = CommandResult<Data>;

type IssueBuilder = (message: string) => Issue;

export interface InventoryCommandTranslation<Field extends string> {
	/** Form-level message when Phoenix sends no `detail`. */
	fallback: string;
	/** Form fields whose API names Phoenix may attribute a rejection to. */
	fields: readonly Field[];
	/** The remote form's `issue` builder (or a fake with the same fields). */
	issue: Record<Field, IssueBuilder>;
	/**
	 * Property Definition labels by id, read only when Phoenix rejects a
	 * property value (`values.<definitionId>`). A failed lookup degrades to
	 * "a property".
	 */
	propertyLabels?: () => Promise<ReadonlyMap<string, string>>;
}

const VALUE_FIELD_PREFIX = "values.";

export async function inventoryCommand<Data, const Field extends string>(
	request: Promise<InventoryCommandResponse<Data>>,
	translation: InventoryCommandTranslation<Field>,
): Promise<InventoryCommandResult<Data>> {
	return commandResult(request, translation.fallback, (fields) =>
		attributeFields(translation, fields),
	);
}

async function attributeFields<Field extends string>(
	translation: InventoryCommandTranslation<Field>,
	fields: ApiFieldMessages[],
): Promise<FieldAttribution> {
	const issues: Issue[] = [];
	let unattributed = false;
	const labels = fields.some(({ field }) =>
		field.startsWith(VALUE_FIELD_PREFIX),
	)
		? await loadLabels(translation.propertyLabels)
		: new Map<string, string>();

	for (const { field, messages } of fields) {
		if (field.startsWith(VALUE_FIELD_PREFIX)) {
			const build = issueFor(translation, "values");
			if (!build) {
				unattributed = true;
				continue;
			}
			const label = labels.get(field.slice(VALUE_FIELD_PREFIX.length));
			issues.push(
				...messages.map((reason) => build(propertyValueMessage(label, reason))),
			);
			continue;
		}
		const build = issueFor(translation, field);
		if (!build) {
			unattributed = true;
			continue;
		}
		issues.push(...messages.map((message) => build(message)));
	}

	// Keep what no field can show visible at form level.
	return { issues, unattributed };
}

function issueFor<Field extends string>(
	translation: InventoryCommandTranslation<Field>,
	field: string,
): IssueBuilder | undefined {
	const known = translation.fields.find((candidate) => candidate === field);
	return known === undefined ? undefined : translation.issue[known];
}

async function loadLabels(
	load: (() => Promise<ReadonlyMap<string, string>>) | undefined,
): Promise<ReadonlyMap<string, string>> {
	try {
		return (await load?.()) ?? new Map();
	} catch (cause) {
		// Labels only name the property; the rejection still reaches the form.
		Sentry.captureException(cause);
		return new Map();
	}
}

/** One sentence per `DhcWeb.InventoryHTTP.value_fields/1` reason. */
function propertyValueMessage(label: string | undefined, reason: string) {
	const name = label ?? "a property";
	const sentence = (() => {
		switch (reason) {
			case "required":
				return `${name} is required`;
			case "type_mismatch":
				return `Enter a valid value for ${name}`;
			case "unknown_option":
				return `Choose one of the options for ${name}`;
			case "retired_option":
				return `The option chosen for ${name} has been retired`;
			case "retired_definition":
				return `${name} has been retired and can no longer be set`;
			case "unknown_definition":
				return `${name} does not belong to this category`;
			default:
				return `${name}: ${reason}`;
		}
	})();
	return sentence.charAt(0).toUpperCase() + sentence.slice(1);
}
