import { describe, expect, it } from "vitest";
import type {
	TrainingAnnouncement,
	TrainingAnnouncementWarning,
} from "@dhc/api-client";
import {
	announcementDraft,
	announcementLifecycle,
	deleteBlockedReason,
	draftPreviewDate,
	dublinToday,
	newAnnouncementDraft,
	postTimeLabel,
	scheduleChanged,
	scheduleLabel,
	warningMessages,
} from "./announcement";

const TODAY = "2026-10-01"; // a Thursday

function announcement(
	overrides: Partial<TrainingAnnouncement> = {},
): TrainingAnnouncement {
	return {
		id: "11111111-1111-1111-1111-111111111111",
		kind: "roll_call",
		weekday: 4,
		oneOffDate: null,
		postTime: "10:00:00",
		title: "Roll call {{date}}",
		message: "Hey! It's {{weekday}}! Who is coming to training tonight?",
		mentionEveryone: true,
		enabled: true,
		retired: false,
		firstAttemptedAt: null,
		createdAt: "2026-09-01T10:00:00Z",
		updatedAt: "2026-09-01T10:00:00Z",
		...overrides,
	};
}

describe("dublinToday", () => {
	it("reads the club's civil day, not the host's", () => {
		// 23:30 UTC is already the next day in Dublin (IST, UTC+1).
		expect(dublinToday(new Date("2026-10-04T23:30:00Z"))).toBe("2026-10-05");
		expect(dublinToday(new Date("2026-10-04T09:30:00Z"))).toBe("2026-10-04");
	});
});

describe("lifecycle", () => {
	it("reads the two booleans the API exposes", () => {
		expect(announcementLifecycle(announcement())).toBe("live");
		expect(announcementLifecycle(announcement({ enabled: false }))).toBe(
			"paused",
		);
		expect(announcementLifecycle(announcement({ retired: true }))).toBe(
			"retired",
		);
		expect(
			announcementLifecycle(announcement({ retired: true, enabled: false })),
		).toBe("retired");
	});
});

describe("scheduleLabel", () => {
	it("names the weekday for a weekly announcement", () => {
		expect(scheduleLabel(announcement())).toBe("Every Thursday at 10:00");
	});

	it("names the date for a one-off", () => {
		expect(
			scheduleLabel(announcement({ weekday: null, oneOffDate: "2026-10-08" })),
		).toBe("One-off on Thursday 8 October 2026 at 10:00");
	});

	it("renders the Dublin civil post time without seconds", () => {
		expect(postTimeLabel("09:05:00")).toBe("09:05");
	});
});

describe("deleteBlockedReason", () => {
	it("allows a delete only while no delivery has been attempted", () => {
		expect(deleteBlockedReason(announcement())).toBeUndefined();
	});

	it("explains the retire-only rule once an attempt exists", () => {
		expect(
			deleteBlockedReason(
				announcement({ firstAttemptedAt: "2026-09-24T10:00:00Z" }),
			),
		).toMatch(/retire/i);
	});

	it("explains that a retired announcement cannot be deleted", () => {
		expect(deleteBlockedReason(announcement({ retired: true }))).toMatch(
			/retired/i,
		);
	});
});

describe("drafts", () => {
	it("starts a new draft from the kind's copy preset and a future date", () => {
		const draft = newAnnouncementDraft(TODAY);
		expect(draft.scheduleType).toBe("weekly");
		// Today is Thursday 4am-safe: a same-day slot can already have elapsed,
		// so the default weekday is the next one.
		expect(draft.weekday).toBe(5);
		expect(draft.postTime).toBe("10:00");
		expect(draft.mentionEveryone).toBe(true);
		expect(draft.message).toContain("{{weekday}}");
		expect(draftPreviewDate(draft, TODAY)).toBe("2026-10-02");
	});

	it("reads an existing announcement back into a draft", () => {
		const draft = announcementDraft(
			announcement({ weekday: null, oneOffDate: "2026-10-08" }),
			TODAY,
		);
		expect(draft.scheduleType).toBe("one_off");
		expect(draft.oneOffDate).toBe("2026-10-08");
		expect(draft.postTime).toBe("10:00");
		expect(draft.title).toBe("Roll call {{date}}");
	});

	it("detects a schedule edit so copy-only saves skip the schedule call", () => {
		const draft = announcementDraft(announcement(), TODAY);
		expect(scheduleChanged(draft, announcement())).toBe(false);
		expect(
			scheduleChanged({ ...draft, postTime: "18:30" }, announcement()),
		).toBe(true);
		expect(
			scheduleChanged(
				{ ...draft, scheduleType: "one_off", oneOffDate: TODAY },
				announcement(),
			),
		).toBe(true);
	});
});

describe("warningMessages", () => {
	it("explains each advisory warning the API can return", () => {
		const warnings: TrainingAnnouncementWarning[] = [
			"slot_collision",
			"exception_intersection_changed",
		];
		const messages = warningMessages(warnings);
		expect(messages).toHaveLength(2);
		expect(messages[0]).toBe(
			"Another announcement is scheduled for the same time. Review the schedules to avoid duplicate posts.",
		);
		expect(messages[1]).toBe(
			"The schedule has changed. Review skipped dates and text changes; they may apply to different posts now.",
		);
	});
});
