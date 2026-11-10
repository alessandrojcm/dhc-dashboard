/**
 * Where a Phoenix Beginners' Workshop field shows up in the dashboard's
 * forms. Phoenix speaks the request body (`feeCents`, one entry per workshop);
 * the forms ask for euro and share most values across a Schedule's dates.
 */
import {
	dottedPath,
	type FormPath,
} from "#lib/server/beginners-workshops/command.js";

// ALE-441: Phoenix's destination fields → the shared destination input's
// control names (`destination-input.svelte`). ALE-442: a refused selection
// shows where the selected place does, under the destination name.
const DESTINATION_CONTROLS = new Map([
	["destinationName", "destination_name"],
	["destinationAddress", "destination_address"],
	["directionsUrl", "directions_url"],
	["destinationPlaceId", "destination_name"],
	["destinationAttributions", "destination_name"],
]);

// Values the Schedule form asks once for every date it schedules.
const SCHEDULE_SHARED_FIELDS = new Set([
	"venue",
	...DESTINATION_CONTROLS.values(),
	"startTime",
	"endTime",
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

/** A form whose controls carry Phoenix's field names unchanged. */
function sameNameFormPath(fields: ReadonlySet<string>) {
	return (field: string): FormPath | undefined =>
		fields.has(field) ? [field] : undefined;
}

/** Public Phoenix field name → the form's own name. */
function formField(field: string): string {
	return field === "feeCents"
		? "fee"
		: (DESTINATION_CONTROLS.get(field) ?? field);
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
const settingsField = sameNameFormPath(SETTINGS_FIELDS);
export function settingsFormPath(field: string): FormPath | undefined {
	return settingsField(formField(field));
}

// ALE-394: the Reschedule dialog's controls.
const RESCHEDULE_FIELDS = new Set([
	"date",
	"startTime",
	"endTime",
	"venue",
	"paymentCutoffDate",
	"paymentCutoffTime",
	"contactFromDate",
	...DESTINATION_CONTROLS.values(),
]);

/**
 * A reschedule or (ALE-441) destination-only field → its control in the
 * Reschedule dialog.
 */
const rescheduleField = sameNameFormPath(RESCHEDULE_FIELDS);
export function rescheduleFormPath(field: string): FormPath | undefined {
	return rescheduleField(formField(field));
}

/** A Staff field → its picker in the Staff dialog. */
export const staffFormPath = sameNameFormPath(STAFF_FIELDS);

// ALE-384: the registration fields of the Fast-track "add a new person" form.
const NEW_PERSON_FIELDS = new Set([
	"firstName",
	"lastName",
	"email",
	"phoneNumber",
	"dateOfBirth",
	"gender",
	"pronouns",
	"medicalConditions",
	"socialMediaConsent",
	"guardianFirstName",
	"guardianLastName",
	"guardianPhoneNumber",
]);

/** A registration field → its control in the Fast-track "add a new person" form. */
export const newPersonFormPath = sameNameFormPath(NEW_PERSON_FIELDS);
