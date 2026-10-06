/**
 * Suppression and Override vocabulary for Training Announcements (ALE-331,
 * spec ALE-317 stories 15–20).
 *
 * Phoenix owns every refusal — a past date, a range whose delivery has begun,
 * an overlapping override, an empty override, an over-long title — and its
 * 422 problem details are surfaced as they arrive. This module decides only
 * *words and dates*: how a range reads, what an override replaces, which
 * slice of a list is shown, and the client-side shape checks that keep an
 * obviously incomplete form from ever reaching the API. Nothing here decides
 * whether a save is allowed.
 */
import type {
	TrainingAnnouncementOverride,
	TrainingAnnouncementSuppression,
} from "@dhc/api-client";
import { announcementDateLabel } from "./announcement";

export type ExceptionKind = "suppression" | "override";

/** How many exception rows the detail column shows before collapsing. */
export const EXCEPTION_LIST_LIMIT = 5;

/** The visible slice of a capped list plus how many rows stay hidden. */
export type CappedExceptionList<T> = {
	visible: T[];
	hidden: number;
};

export type SuppressionFieldErrors = {
	fromDate?: string;
	toDate?: string;
};

export type OverrideFieldErrors = SuppressionFieldErrors & {
	title?: string;
	message?: string;
};

export type SuppressionField = keyof SuppressionFieldErrors;

export type OverrideField = keyof OverrideFieldErrors;

export type SuppressionDraft = {
	/** Dublin civil date as `YYYY-MM-DD`. */
	fromDate: string;
	/** Dublin civil date as `YYYY-MM-DD`, inclusive. */
	toDate: string;
};

export type OverrideDraft = SuppressionDraft & {
	title: string;
	message: string;
};

/** One date reads as the date; a range reads as `8 Oct → 22 Oct 2026`. */
export function exceptionRangeLabel(fromDate: string, toDate: string): string {
	if (fromDate === toDate) return announcementDateLabel(fromDate);
	return `${announcementDateLabel(fromDate)} → ${announcementDateLabel(toDate)}`;
}

export function suppressionRangeLabel(
	suppression: Pick<TrainingAnnouncementSuppression, "fromDate" | "toDate">,
): string {
	return exceptionRangeLabel(suppression.fromDate, suppression.toDate);
}

export function overrideRangeLabel(
	override: Pick<TrainingAnnouncementOverride, "fromDate" | "toDate">,
): string {
	return exceptionRangeLabel(override.fromDate, override.toDate);
}

/** What an override replaces, in committee words. */
export function overrideSummary(
	override: Pick<TrainingAnnouncementOverride, "title" | "message">,
): string {
	const replacesTitle = (override.title ?? "") !== "";
	const replacesMessage = (override.message ?? "") !== "";
	if (replacesTitle && replacesMessage) return "Replaces the title and message";
	if (replacesTitle) return "Replaces the title";
	if (replacesMessage) return "Replaces the message";
	return "No replacement copy";
}

/**
 * The visible slice of a capped exception list, plus how many rows stay
 * hidden. The list order is Phoenix's (by range start, then creation); the
 * cap never reorders, it only truncates.
 */
export function cappedExceptions<T>(
	rows: readonly T[],
): CappedExceptionList<T> {
	if (rows.length <= EXCEPTION_LIST_LIMIT)
		return { visible: [...rows], hidden: 0 };
	return {
		visible: rows.slice(0, EXCEPTION_LIST_LIMIT),
		hidden: rows.length - EXCEPTION_LIST_LIMIT,
	};
}

/** The least the next-post read needs: the thread name Phoenix computed. */
export type NextTitled = {
	subject: "occurrence" | "holiday";
	threadName: string | null;
};

/**
 * The resolved title of the next post — the thread name Phoenix computed,
 * never the announcement's template; a holiday notice has no thread and
 * reads as one. `undefined` while the read is pending or when there is no
 * upcoming post to name.
 */
export function nextResolvedTitle(
	occurrences: readonly NextTitled[] | undefined,
): string | undefined {
	const next = occurrences?.[0];
	if (next?.subject === "holiday") return "Holiday notice";
	const threadName = next?.threadName;
	return threadName ? threadName : undefined;
}

export function newSuppressionDraft(today: string): SuppressionDraft {
	return { fromDate: today, toDate: today };
}

export function newOverrideDraft(
	today: string,
	date?: string,
	initial?: { title?: string; message?: string },
): OverrideDraft {
	const day = date ?? today;
	return {
		fromDate: day,
		toDate: day,
		title: initial?.title ?? "",
		message: initial?.message ?? "",
	};
}

/** Client-side shape checks only; Phoenix re-decides every refusal. */
export function validateSuppressionDraft(
	draft: SuppressionDraft,
): SuppressionFieldErrors {
	const errors: SuppressionFieldErrors = {};
	if (!draft.fromDate) errors.fromDate = "Choose the first date.";
	if (!draft.toDate) errors.toDate = "Choose the last date.";
	if (draft.fromDate && draft.toDate && draft.fromDate > draft.toDate) {
		errors.toDate = "The last date must be on or after the first date.";
	}
	return errors;
}

/** An override replaces the title, the message, or both — never neither. */
export function validateOverrideDraft(
	draft: OverrideDraft,
): OverrideFieldErrors {
	const range = validateSuppressionDraft(draft);
	const errors: OverrideFieldErrors = {
		...range,
	};
	if (draft.title.trim() === "" && draft.message.trim() === "") {
		errors.title = "Enter a title or message to save a change.";
	}
	return errors;
}

export function hasDraftErrors(
	errors: Record<string, string | undefined>,
): boolean {
	return Object.values(errors).some((message) => message !== undefined);
}

/**
 * What an overlapping-override refusal means, in committee words. Phoenix
 * rejects the write with `overlaps another override for this announcement`
 * (the GiST exclusion), which never names the way out: the existing text
 * change must be deleted before a new one can cover its dates.
 */
export const OVERRIDE_OVERLAP_GUIDANCE =
	"These dates overlap an existing text change. Delete the existing text change before creating a new one.";

function isOverrideOverlapMessage(message: string): boolean {
	return message.includes("overlaps another override");
}

/** Rewords an overlap refusal; every other message passes through untouched. */
export function friendlyOverrideFieldMessage(message: string): string {
	return isOverrideOverlapMessage(message)
		? OVERRIDE_OVERLAP_GUIDANCE
		: message;
}

/** Rewords an overlap refusal detail; every other detail passes through. */
export function friendlyOverrideDetail(
	detail: string | undefined,
): string | undefined {
	if (!detail) return detail;
	return isOverrideOverlapMessage(detail) ? OVERRIDE_OVERLAP_GUIDANCE : detail;
}
