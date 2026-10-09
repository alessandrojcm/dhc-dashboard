/**
 * Field validators shared by the person-details form schemas.
 *
 * Internal building block: forms import their own form schema (for example
 * `#lib/schemas/beginnersWaitlist.js`), never these validators directly. Every
 * validator takes the remote form's string input, so the schemas built from
 * them can be passed to `form(...)` and `.preflight(...)` unchanged.
 *
 * Dates of birth stay `YYYY-MM-DD` strings throughout: the age rules parse the
 * string with dayjs (a bare ISO date is local midnight), never via `new Date`.
 */
import * as Sentry from "@sentry/sveltekit";
import dayjs from "dayjs";
import {
	formatIncompletePhoneNumber,
	parsePhoneNumber,
} from "libphonenumber-js/min";
import * as v from "valibot";

/** Minimum age to train, for insurance reasons. */
export const MINIMUM_AGE = 16;
/** Applicants younger than this need a guardian. */
export const ADULT_AGE = 18;

/** Whole years between a `YYYY-MM-DD` date of birth and today. */
export const calculateAge = (dateOfBirth: string) =>
	dayjs().diff(dayjs(dateOfBirth), "year");

/** Whether a `YYYY-MM-DD` date of birth belongs to someone under 18. */
export const isMinor = (dateOfBirth: string) =>
	calculateAge(dateOfBirth) < ADULT_AGE;

const isValidPhoneNumber = (input: string) => {
	try {
		return Boolean(parsePhoneNumber(input, "IE")?.isValid());
	} catch (error) {
		Sentry.captureMessage(
			`Phone number validation error: ${String(error)}`,
			"warning",
		);
		return false;
	}
};

/** Required text, such as a first or last name. */
export const requiredText = (message: string) =>
	v.pipe(v.string(), v.nonEmpty(message));

/** A required email address, lowercased. */
export const email = (message = "Please enter your email.") =>
	v.pipe(
		v.string(),
		v.nonEmpty(message),
		v.email("Email is invalid."),
		v.toLowerCase(),
	);

/** A required phone number, validated for Ireland by default and formatted. */
export const phoneNumber = (message = "Phone number is required.") =>
	v.pipe(
		v.string(),
		v.nonEmpty(message),
		v.check(isValidPhoneNumber, "Invalid phone number"),
		v.transform((input) => formatIncompletePhoneNumber(input)),
	);

const isoDate = v.pipe(v.string(), v.isoDate());
const isOldEnough = (input: string) => calculateAge(input) >= MINIMUM_AGE;

/** A required `YYYY-MM-DD` date of birth of someone at least 16 years old. */
export const dateOfBirth = () =>
	v.pipe(
		v.string(),
		v.isoDate("Date of birth is required."),
		v.check(
			// A malformed date already has its issue; don't add a second one.
			(input) => !v.is(isoDate, input) || isOldEnough(input),
			`You must be at least ${MINIMUM_AGE} years old.`,
		),
	);

/**
 * Whether guardian details are owed: only for a valid date of birth of an
 * applicant old enough to join but under 18. Validation issues leave the
 * dataset typed, so the guardian checks must not rely on `dateOfBirth`
 * having passed its own pipe.
 */
const needsGuardian = (input: string) =>
	v.is(isoDate, input) && isOldEnough(input) && isMinor(input);

/** Optional pronouns written between slashes; blank when not shared. */
export const pronouns = () =>
	v.optional(
		v.pipe(
			v.string(),
			v.check(
				(input) => input === "" || /^\/?[\w-]+(\/[\w-]+)*\/?$/.test(input),
				"Pronouns must be written between slashes (e.g., he/him/they), or left blank.",
			),
		),
		"",
	);

/** A required gender selection. */
export const gender = () => requiredText("Please select your gender.");

/**
 * Guardian inputs as the form submits them. They are only rendered for
 * minors, so each one may be absent; `guardianRules` decides whether they are
 * required.
 */
export const guardianEntries = {
	guardianFirstName: v.optional(v.string()),
	guardianLastName: v.optional(v.string()),
	guardianPhoneNumber: v.optional(v.string()),
};

type GuardianKey = keyof typeof guardianEntries;

/** The part of a form the guardian rules read, parsed before they branch. */
const guardianRulesInput = v.object({
	dateOfBirth: v.string(),
	...guardianEntries,
});

type GuardianInput = v.InferOutput<typeof guardianRulesInput>;

/** A form's output once the guardian rules ran: guardian fields only for minors. */
export type WithGuardian<TInput extends GuardianInput> = Omit<
	TInput,
	GuardianKey
> &
	Partial<Record<GuardianKey, string>>;

/** Each guardian field's rule for a minor; `undefined` when the value is fine. */
const guardianIssue = {
	guardianFirstName: (value) =>
		value ? undefined : "Guardian first name is required for under 18s.",
	guardianLastName: (value) =>
		value ? undefined : "Guardian last name is required for under 18s.",
	guardianPhoneNumber: (value) => {
		if (!value) return "Guardian phone number is required for under 18s.";
		return isValidPhoneNumber(value) ? undefined : "Invalid phone number";
	},
} satisfies Record<
	GuardianKey,
	(value: string | undefined) => string | undefined
>;

const guardianKeys = v.keyof(v.object(guardianEntries)).options;

/**
 * Pipe actions for an object schema that spreads `guardianEntries` beside a
 * `dateOfBirth`. A minor must name a guardian, with each issue reported at its
 * guardian field so the remote form shows it there, and gets the guardian
 * phone formatted; an adult has the guardian fields stripped from the output.
 *
 * The check runs even when other fields have issues (like `partialCheck`), so
 * guardian issues appear together with the rest of the form's.
 */
export const guardianRules = <TInput extends GuardianInput>() =>
	[
		v.rawCheck<TInput>(({ dataset, addIssue }) => {
			const parsed = v.safeParse(guardianRulesInput, dataset.value);
			if (!parsed.success || !needsGuardian(parsed.output.dateOfBirth)) {
				return;
			}
			const input = parsed.output;
			for (const key of guardianKeys) {
				const message = guardianIssue[key](input[key]);
				if (!message) continue;
				addIssue({
					message,
					path: [
						{ type: "object", origin: "value", input, key, value: input[key] },
					],
				});
			}
		}),
		v.transform<TInput, WithGuardian<TInput>>((input) => {
			const {
				guardianFirstName,
				guardianLastName,
				guardianPhoneNumber,
				...rest
			} = input;
			if (!isMinor(input.dateOfBirth)) return rest;
			return {
				...rest,
				guardianFirstName,
				guardianLastName,
				guardianPhoneNumber:
					guardianPhoneNumber &&
					formatIncompletePhoneNumber(guardianPhoneNumber),
			};
		}),
	] as const;

/**
 * A required civil `YYYY-MM-DD` date (a date picker's value). One check, so
 * a blank picker reports one issue.
 */
export const civilDate = (message: string) =>
	v.pipe(v.string(), v.isoDate(message));

/**
 * An optional civil `YYYY-MM-DD` date: a blank picker means "use Phoenix's
 * default", so it leaves the output without the key.
 */
export const optionalCivilDate = (message: string) =>
	v.pipe(
		v.optional(v.string(), ""),
		v.transform((input) => input || undefined),
		v.optional(v.pipe(v.string(), v.isoDate(message))),
	);

/** A required `HH:MM` wall-clock time (a `type="time"` input). */
export const wallTime = (message: string) =>
	v.pipe(v.string(), v.regex(/^([01][0-9]|2[0-3]):[0-5][0-9]$/, message));

/** An optional `HH:MM` wall-clock time; blank leaves the output without it. */
export const optionalWallTime = (message: string) =>
	v.pipe(
		v.optional(v.string(), ""),
		v.transform((input) => input || undefined),
		v.optional(
			v.pipe(v.string(), v.regex(/^([01][0-9]|2[0-3]):[0-5][0-9]$/, message)),
		),
	);

/**
 * A required whole number of at least `min` (a number input). One check, so
 * a bad value reports one issue (remote-form issue lists key on the message).
 */
export const wholeNumber = (message: string, min = 1) =>
	v.pipe(
		v.number(message),
		v.check((input) => Number.isInteger(input) && input >= min, message),
	);

/** A required euro amount up to €999.99, as whole cents. */
export const euroAmountInCents = (message: string) =>
	v.pipe(
		v.number(message),
		v.minValue(0.01, message),
		v.maxValue(999.99, "The fee can be at most €999.99."),
		v.transform((euros) => Math.round(euros * 100)),
	);

/**
 * ALE-379: an optional Member pick (a combobox's hidden input). Blank means
 * "nobody", which Phoenix receives as `null`.
 */
export const optionalPrincipalId = (message: string) =>
	v.pipe(
		v.optional(v.string(), ""),
		v.transform((input) => input || null),
		v.nullable(v.pipe(v.string(), v.uuid(message))),
	);

/** ALE-379: several Member picks (one hidden input each); none is `[]`. */
export const principalIds = (message: string) =>
	v.optional(v.array(v.pipe(v.string(), v.uuid(message))), []);
