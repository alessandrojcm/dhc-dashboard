/**
 * How a Training Announcement's stored schedule and copy read on screen
 * (ALE-330), and the draft the side sheet edits.
 *
 * This module decides *words and dates*, never whether a save is allowed:
 * Phoenix owns the not-elapsed rule, the schedule shape and every lifecycle
 * guard, and its 422 problem details are surfaced as they arrive. The only
 * schedule knowledge duplicated here is picking a sensible default date for a
 * brand-new draft, so opening the sheet cannot immediately fail on an elapsed
 * slot.
 */
import type {
	TrainingAnnouncement,
	TrainingAnnouncementKind,
	TrainingAnnouncementWarning,
} from "@dhc/api-client";
import { COPY_PRESETS, WEEKDAY_NAMES } from "./copy";

/** Live, paused by an Announcement Disablement, or terminally retired. */
export type AnnouncementLifecycle = "live" | "paused" | "retired";

export const ANNOUNCEMENT_LIFECYCLE_LABELS = {
	live: "Live",
	paused: "Paused",
	retired: "Retired",
} satisfies Record<AnnouncementLifecycle, string>;

export type AnnouncementScheduleType = "weekly" | "one_off";

/**
 * What one committed write produced: the announcement as Phoenix now sees it,
 * plus any advisory warnings. `updateCopy`, the lifecycle commands and a
 * copy-only edit have no schedule response, so their `warnings` is empty.
 */
export type AnnouncementSave = {
	announcement: TrainingAnnouncement;
	warnings: TrainingAnnouncementWarning[];
};

/**
 * Europe/Dublin's today — the club's civil day. The page reads announcements
 * in the browser, so the server hands the sheet this date instead of letting a
 * reader's own time zone pick the default dates.
 */
export function dublinToday(now: Date = new Date()): string {
	// en-CA formats as an ISO date, so the result never depends on the host's
	// locale settings.
	return new Intl.DateTimeFormat("en-CA", {
		timeZone: "Europe/Dublin",
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
	}).format(now);
}

/** The side sheet's editable copy of one announcement's schedule and copy. */
export type AnnouncementDraft = {
	kind: TrainingAnnouncementKind;
	scheduleType: AnnouncementScheduleType;
	/** ISO weekday, 1 (Monday) to 7 (Sunday). */
	weekday: number;
	/** Dublin civil date as `YYYY-MM-DD`. */
	oneOffDate: string;
	/** Dublin civil time as `HH:MM`. */
	postTime: string;
	title: string;
	message: string;
	mentionEveryone: boolean;
};

export function announcementLifecycle(
	announcement: TrainingAnnouncement,
): AnnouncementLifecycle {
	if (announcement.retired) return "retired";
	return announcement.enabled ? "live" : "paused";
}

/** `HH:MM:SS` from Phoenix as the `HH:MM` an `<input type="time">` wants. */
export function postTimeLabel(postTime: string): string {
	return postTime.slice(0, 5);
}

function civilDate(isoDate: string): Date {
	// Anchored at UTC midnight so the formatted weekday never shifts with the
	// reader's own time zone.
	return new Date(`${isoDate}T00:00:00Z`);
}

function isoWeekday(isoDate: string): number {
	const day = civilDate(isoDate).getUTCDay();
	return day === 0 ? 7 : day;
}

function addDays(isoDate: string, days: number): string {
	const date = civilDate(isoDate);
	date.setUTCDate(date.getUTCDate() + days);
	return date.toISOString().slice(0, 10);
}

/**
 * `Thursday 8 October 2026` in Europe/Dublin civil terms. Built from parts
 * rather than `format()` because en-GB inserts a comma after the weekday,
 * while Phoenix renders `{{date}}` as `Thursday 25 September` — the sheet
 * shows both, so they should read alike.
 */
export function announcementDateLabel(isoDate: string): string {
	const parts = new Intl.DateTimeFormat("en-GB", {
		weekday: "long",
		day: "numeric",
		month: "long",
		year: "numeric",
		timeZone: "UTC",
	}).formatToParts(civilDate(isoDate));
	const byType = new Map(parts.map((part) => [part.type, part.value]));
	const order: Intl.DateTimeFormatPartTypes[] = [
		"weekday",
		"day",
		"month",
		"year",
	];
	return order.map((type) => byType.get(type) ?? "").join(" ");
}

/**
 * The next occurrence date of a weekly announcement: today when today is the
 * chosen weekday, otherwise the first such day after it. Which of those slots
 * has already elapsed today is Phoenix's to decide.
 */
export function nextOccurrenceDate(weekday: number, today: string): string {
	const delta = (weekday - isoWeekday(today) + 7) % 7;
	return addDays(today, delta);
}

export function scheduleLabel(announcement: TrainingAnnouncement): string {
	const time = postTimeLabel(announcement.postTime);
	if (announcement.weekday !== null) {
		return `Every ${WEEKDAY_NAMES[announcement.weekday]} at ${time}`;
	}
	const date = announcement.oneOffDate;
	return date
		? `One-off on ${announcementDateLabel(date)} at ${time}`
		: `One-off at ${time}`;
}

/**
 * Why `DELETE /training-announcements/:id` is refused, or `undefined` when it
 * is allowed. Phoenix answers an attempted announcement with `attempted`; the
 * UI refuses it first so the card can explain the retire-only rule.
 */
export function deleteBlockedReason(
	announcement: TrainingAnnouncement,
): string | undefined {
	if (announcement.retired) {
		return "Retired announcements keep their history and cannot be deleted.";
	}
	if (announcement.firstAttemptedAt !== null) {
		return "This announcement has already posted, so its history is kept. Retire it instead.";
	}
	return undefined;
}

export function newAnnouncementDraft(today: string): AnnouncementDraft {
	const preset = COPY_PRESETS.roll_call;
	return {
		kind: "roll_call",
		scheduleType: "weekly",
		// The next weekday rather than today's: today's slot may already have
		// elapsed, and a new draft should not open on a guaranteed rejection.
		weekday: nextOccurrenceWeekday(today),
		oneOffDate: addDays(today, 1),
		postTime: "10:00",
		title: preset.title,
		message: preset.message,
		mentionEveryone: true,
	};
}

function nextOccurrenceWeekday(today: string): number {
	return (isoWeekday(today) % 7) + 1;
}

export function announcementDraft(
	announcement: TrainingAnnouncement,
	today: string,
): AnnouncementDraft {
	const scheduleType: AnnouncementScheduleType =
		announcement.weekday !== null ? "weekly" : "one_off";
	return {
		kind: announcement.kind,
		scheduleType,
		weekday: announcement.weekday ?? nextOccurrenceWeekday(today),
		oneOffDate: announcement.oneOffDate ?? addDays(today, 1),
		postTime: postTimeLabel(announcement.postTime),
		title: announcement.title,
		message: announcement.message,
		mentionEveryone: announcement.mentionEveryone,
	};
}

/** The date the sheet previews: the one-off's date, or the next weekly slot. */
export function draftPreviewDate(
	draft: AnnouncementDraft,
	today: string,
): string {
	return draft.scheduleType === "one_off"
		? draft.oneOffDate
		: nextOccurrenceDate(draft.weekday, today);
}

/**
 * Whether saving this draft needs the schedule call. The two commands are
 * separate because the API models schedule and copy as separate writes, so an
 * unchanged schedule must not reschedule an announcement (and cannot produce
 * the advisory warnings a schedule edit may return).
 */
export function scheduleChanged(
	draft: AnnouncementDraft,
	announcement: TrainingAnnouncement,
): boolean {
	const postTime = postTimeLabel(announcement.postTime);
	if (draft.scheduleType === "weekly") {
		return (
			draft.weekday !== announcement.weekday ||
			draft.postTime !== postTime ||
			announcement.oneOffDate !== null
		);
	}
	return (
		draft.oneOffDate !== (announcement.oneOffDate ?? "") ||
		draft.postTime !== postTime ||
		announcement.weekday !== null
	);
}

/** Advisory `warnings[]` from create/updateSchedule, in committee words. */
export function warningMessages(
	warnings: readonly TrainingAnnouncementWarning[],
): string[] {
	return warnings.map((warning) =>
		warning === "slot_collision"
			? "Another announcement already posts in one of these slots. Nothing was blocked — check the times still make sense."
			: "A schedule change moved which future skipped dates or copy changes still apply. Dormant exceptions can start applying again.",
	);
}
