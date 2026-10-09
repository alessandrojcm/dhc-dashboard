/**
 * Where a Phoenix Beginners' Workshop field shows up in the dashboard's
 * forms. Phoenix speaks the request body (`feeCents`, one entry per workshop);
 * the forms ask for euro and share most values across a Schedule's dates.
 */
import {
	dottedPath,
	type FormPath,
} from "#lib/server/beginners-workshops/command.js";

// Values the Schedule form asks once for every date it schedules.
const SCHEDULE_SHARED_FIELDS = new Set([
	"venue",
	"startTime",
	"capacity",
	"fee",
	"paymentWindowDays",
	"coachPrincipalId",
	"assistantPrincipalIds",
]);

const STAFF_FIELDS = new Set(["coachPrincipalId", "assistantPrincipalIds"]);

const SETTINGS_FIELDS = new Set([
	"capacity",
	"fee",
	"paymentCutoffDate",
	"paymentCutoffTime",
	"contactFromDate",
	"paymentWindowDays",
]);

/** Public Phoenix field name → the form's own name. */
function formField(field: string): string {
	return field === "feeCents" ? "fee" : field;
}

/** `workshops.<i>.<field>` → the shared control, or that date's control. */
export function scheduleFormPath(field: string): FormPath | undefined {
	const [root, index, name, ...rest] = dottedPath(field);
	if (root !== "workshops" || !Number.isInteger(index) || name === undefined)
		return undefined;
	if (rest.length > 0) return undefined;
	const key = formField(String(name));
	return SCHEDULE_SHARED_FIELDS.has(key) ? [key] : ["workshops", index, key];
}

/** A settings field → its control in the Capacity / fee / cutoff dialog. */
export function settingsFormPath(field: string): FormPath | undefined {
	const key = formField(field);
	return SETTINGS_FIELDS.has(key) ? [key] : undefined;
}

/** A Staff field → its picker in the Staff dialog. */
export function staffFormPath(field: string): FormPath | undefined {
	return STAFF_FIELDS.has(field) ? [field] : undefined;
}
