/**
 * Copy vocabulary for Training Announcements (ALE-330, spec ALE-317).
 *
 * The presets are the retired Discord bot's wording, so entering them during
 * cutover changes nothing members see. The stored *source* omits the
 * `@everyone` mention on purpose: `Dhc.TrainingAnnouncements.Copy` prepends
 * that line from the announcement's mention setting, so a typed mention would
 * either double up or read as a mention that never pings. The accepted drifts
 * are the thread name — the bot posted `Roll call September 25`, the
 * announcement renders `Roll call Thursday 25 September` — and the sparring
 * message, which asks for next Sunday in plain words instead of the
 * `{{weekday}}` token because sparring is always on Sundays.
 *
 * Everything here is presentation: no component reaches for Phoenix's renderer
 * to decide what a token means, and the preview endpoint stays the authority
 * for what will actually be posted.
 */
import type { TrainingAnnouncementKind } from "@dhc/api-client";

export type CopyPreset = {
	title: string;
	message: string;
};

/** Tokens a message template may use (`{{title}}` is title-only). */
export const MESSAGE_TOKENS = ["{{title}}", "{{date}}", "{{weekday}}"] as const;

/**
 * Tokens a title template may use. `{{title}}` is deliberately absent: the
 * resolved title *is* the thread name, so it cannot reference itself.
 */
export const TITLE_TOKENS = ["{{date}}", "{{weekday}}"] as const;

export const PLACEHOLDER_LABELS = {
	"{{date}}": "Date",
	"{{weekday}}": "Weekday",
	"{{title}}": "Title",
};

export const COPY_PRESETS = {
	roll_call: {
		title: "Roll call {{date}}",
		message: "Hey! It's {{weekday}}! Who is coming to training tonight? ⚔️",
	},
	sparring: {
		title: "Sparring {{date}}",
		message: "Hey! Who is down for sparring next Sunday? ⚔️",
	},
} satisfies Record<TrainingAnnouncementKind, CopyPreset>;

export const KIND_LABELS = {
	roll_call: "Roll call",
	sparring: "Sparring",
} satisfies Record<TrainingAnnouncementKind, string>;

/**
 * Where each kind posts, in the words the deployment uses. The API exposes no
 * channel id, so this stays a description rather than a fabricated handle.
 */
export const KIND_CHANNEL_LABELS = {
	roll_call: "Roll call channel",
	sparring: "Sparring channel",
} satisfies Record<TrainingAnnouncementKind, string>;

/**
 * Weekday names indexed by the API's `weekday`, which is an Elixir
 * `Date.day_of_week/1` value: 1 is Monday, 7 is Sunday. Index 0 is unused.
 */
export const WEEKDAY_NAMES = [
	"",
	"Monday",
	"Tuesday",
	"Wednesday",
	"Thursday",
	"Friday",
	"Saturday",
	"Sunday",
] as const;

/** Weekday options for the schedule picker, ordered Monday to Sunday. */
export const WEEKDAY_OPTIONS = WEEKDAY_NAMES.slice(1).map((name, index) => ({
	value: index + 1,
	name,
}));
