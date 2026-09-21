// PROTOTYPE — throwaway. In-memory Training fixtures shared by every variant.
// Vocabulary follows ALE-308/ALE-309: Training, Training Occurrence,
// Training Suppression, Training Override, Discord Training Delivery.
import dayjs, { type Dayjs } from "dayjs";

export type NotificationKind = "roll_call" | "sparring";

export type Schedule =
	| { type: "weekly"; weekday: number; startTime: string; endTime: string }
	| { type: "one_off"; date: string; startTime: string; endTime: string };

export type Training = {
	id: string;
	kind: NotificationKind;
	title: string;
	message: string;
	everyone: boolean;
	enabled: boolean;
	schedule: Schedule;
	/** First delivery attempt already happened → can only be retired. */
	attempted: boolean;
};

export type Suppression = {
	id: string;
	trainingId: string;
	from: string;
	to: string;
	note?: string;
};

export type Override = {
	id: string;
	trainingId: string;
	from: string;
	to: string;
	title?: string;
	message?: string;
};

export type Holiday = { date: string; name: string };

export type DeliveryState =
	| "delivered"
	| "thread_failed"
	| "message_uncertain"
	| "blocked"
	| "missed"
	| "skipped";

export type Delivery = {
	trainingId: string;
	date: string;
	state: DeliveryState;
	messageId?: string;
	threadId?: string;
	reason?: string;
	at?: string;
};

/** Which rule won for this occurrence (ALE-308 precedence order). */
export type Decision =
	| "bank_holiday"
	| "disabled"
	| "suppressed"
	| "overridden"
	| "default";

export type Occurrence = {
	key: string;
	training: Training;
	date: string;
	startTime: string;
	endTime: string;
	decision: Decision;
	holiday?: Holiday;
	suppression?: Suppression;
	override?: Override;
	title: string;
	messageSource: string;
	rendered: string;
	threadName: string;
	willPost: boolean;
	past: boolean;
	delivery?: Delivery;
};

export type HolidayAnnouncement = {
	key: string;
	date: string;
	holiday: Holiday;
	phase: "day_before" | "same_day";
	rendered: string;
	past: boolean;
	delivery?: Delivery;
};

export const TODAY = "2026-09-21";
export const DATE_FORMAT = "YYYY-MM-DD";

export const KIND_LABEL = {
	roll_call: "Roll call",
	sparring: "Sparring",
} satisfies Record<NotificationKind, string>;

export const CHANNEL = {
	roll_call: "#training",
	sparring: "#sparring",
} satisfies Record<NotificationKind, string>;

export const ANNOUNCEMENT_CHANNEL = "#announcements";

export const WEEKDAYS = [
	"Sunday",
	"Monday",
	"Tuesday",
	"Wednesday",
	"Thursday",
	"Friday",
	"Saturday",
];

export const PRESETS = {
	roll_call: {
		title: "Roll call {{date}}",
		message:
			"Hey! It's {{date}}! Who is coming to training tonight? Doors open {{startTime}}.",
	},
	sparring: {
		title: "Sparring {{date}}",
		message:
			"Hey! Who is down for sparring this {{date}}? {{startTime}} start.",
	},
} satisfies Record<NotificationKind, { title: string; message: string }>;

export const HOLIDAYS: Holiday[] = [
	{ date: "2026-08-03", name: "August Bank Holiday" },
	{ date: "2026-10-26", name: "October Bank Holiday" },
	{ date: "2026-12-25", name: "Christmas Day" },
	{ date: "2026-12-26", name: "St Stephen's Day" },
	{ date: "2027-01-01", name: "New Year's Day" },
	{ date: "2027-02-01", name: "St Brigid's Day" },
	{ date: "2027-03-17", name: "St Patrick's Day" },
];

// Form draft shared by the variants' create/edit UIs.
export type TrainingDraft = {
	kind: NotificationKind;
	scheduleType: "weekly" | "one_off";
	weekday: number;
	date: string;
	startTime: string;
	endTime: string;
	title: string;
	message: string;
	everyone: boolean;
};

export function emptyDraft(
	kind: NotificationKind = "roll_call",
): TrainingDraft {
	return {
		kind,
		scheduleType: "weekly",
		weekday: 1,
		date: TODAY,
		startTime: "10:00",
		endTime: "10:15",
		title: PRESETS[kind].title,
		message: PRESETS[kind].message,
		everyone: true,
	};
}

let seq = 100;
const nextId = (prefix: string) => `${prefix}-${seq++}`;

class TrainingStore {
	trainings = $state<Training[]>([
		{
			id: "t-monday",
			kind: "roll_call",
			title: PRESETS.roll_call.title,
			message: PRESETS.roll_call.message,
			everyone: true,
			enabled: true,
			schedule: {
				type: "weekly",
				weekday: 1,
				startTime: "10:00",
				endTime: "10:15",
			},
			attempted: true,
		},
		{
			id: "t-monday-beginners",
			kind: "roll_call",
			title: "Beginners roll call {{date}}",
			message:
				"Beginners course tonight ({{date}}) — who is coming? Doors {{startTime}}, loaner gear provided.",
			everyone: false,
			enabled: true,
			schedule: {
				type: "weekly",
				weekday: 1,
				startTime: "09:00",
				endTime: "09:15",
			},
			attempted: true,
		},
		{
			id: "t-thursday",
			kind: "roll_call",
			title: PRESETS.roll_call.title,
			message: PRESETS.roll_call.message,
			everyone: true,
			enabled: true,
			schedule: {
				type: "weekly",
				weekday: 4,
				startTime: "10:00",
				endTime: "10:15",
			},
			attempted: true,
		},
		{
			id: "t-sunday",
			kind: "sparring",
			title: PRESETS.sparring.title,
			message: PRESETS.sparring.message,
			everyone: true,
			enabled: true,
			schedule: {
				type: "weekly",
				weekday: 0,
				startTime: "09:30",
				endTime: "09:45",
			},
			attempted: true,
		},
		{
			id: "t-halloween",
			kind: "sparring",
			title: "Halloween open sparring",
			message:
				"One-off open sparring on {{date}} from {{startTime}}. Costumes optional, masks mandatory.",
			everyone: false,
			enabled: true,
			schedule: {
				type: "one_off",
				date: "2026-10-31",
				startTime: "11:00",
				endTime: "11:15",
			},
			attempted: false,
		},
	]);

	suppressions = $state<Suppression[]>([
		{
			id: "s-1",
			trainingId: "t-thursday",
			from: "2026-10-01",
			to: "2026-10-01",
			note: "Hall booked for the AGM",
		},
		{
			id: "s-2",
			trainingId: "t-sunday",
			from: "2026-12-20",
			to: "2027-01-03",
			note: "Winter break",
		},
	]);

	overrides = $state<Override[]>([
		{
			id: "o-1",
			trainingId: "t-monday",
			from: "2026-10-05",
			to: "2026-10-19",
			title: "Longsword fundamentals block — {{date}}",
			message:
				"Fundamentals block week: who is coming tonight? Beginners welcome, loaner gear available. Doors {{startTime}}.",
		},
		{
			id: "o-2",
			trainingId: "t-sunday",
			from: "2026-09-27",
			to: "2026-09-27",
			message:
				"Sparring this {{date}} — bring your own gorget, the club set is out for maintenance.",
		},
	]);

	deliveries = $state<Delivery[]>([
		{
			trainingId: "t-monday",
			date: "2026-09-14",
			state: "delivered",
			messageId: "1417…8821",
			threadId: "1417…8834",
			at: "2026-09-14T09:00:04Z",
		},
		{
			trainingId: "t-thursday",
			date: "2026-09-17",
			state: "thread_failed",
			messageId: "1418…1043",
			reason: "Thread creation returned 5xx twice; message stands",
			at: "2026-09-17T09:00:02Z",
		},
		{
			trainingId: "t-sunday",
			date: "2026-09-13",
			state: "delivered",
			messageId: "1416…3390",
			threadId: "1416…3401",
			at: "2026-09-13T08:30:03Z",
		},
		{
			trainingId: "t-sunday",
			date: "2026-09-20",
			state: "message_uncertain",
			reason: "Worker died while posting_message; no repost attempted",
			at: "2026-09-20T08:30:01Z",
		},
		{
			trainingId: "t-monday",
			date: "2026-09-07",
			state: "missed",
			reason: "Job ran after midnight Europe/Dublin",
			at: "2026-09-08T00:12:40Z",
		},
		{
			trainingId: "t-thursday",
			date: "2026-09-10",
			state: "blocked",
			reason: "403 Missing MENTION_EVERYONE in #training",
			at: "2026-09-10T09:00:01Z",
		},
	]);

	get(id: string) {
		return this.trainings.find((training) => training.id === id);
	}

	add(input: Omit<Training, "id" | "attempted">) {
		const training: Training = { ...input, id: nextId("t"), attempted: false };
		this.trainings.push(training);
		return training;
	}

	update(id: string, patch: Partial<Omit<Training, "id" | "kind">>) {
		const index = this.trainings.findIndex((training) => training.id === id);
		if (index === -1) return;
		this.trainings[index] = { ...this.trainings[index]!, ...patch };
	}

	setEnabled(id: string, enabled: boolean) {
		this.update(id, { enabled });
	}

	remove(id: string) {
		this.trainings = this.trainings.filter((training) => training.id !== id);
		this.suppressions = this.suppressions.filter((s) => s.trainingId !== id);
		this.overrides = this.overrides.filter((o) => o.trainingId !== id);
	}

	suppress(input: Omit<Suppression, "id">) {
		const suppression = { ...input, id: nextId("s") };
		this.suppressions.push(suppression);
		return suppression;
	}

	unsuppress(id: string) {
		this.suppressions = this.suppressions.filter((s) => s.id !== id);
	}

	override(
		input: Omit<Override, "id">,
	): { ok: true } | { ok: false; error: string } {
		const clash = this.overrides.find(
			(existing) =>
				existing.trainingId === input.trainingId &&
				rangesOverlap(existing, input),
		);
		if (clash) {
			return {
				ok: false,
				error: `Overlaps the existing override ${formatRange(clash.from, clash.to)}. Override ranges for one Training cannot overlap.`,
			};
		}
		this.overrides.push({ ...input, id: nextId("o") });
		return { ok: true };
	}

	removeOverride(id: string) {
		this.overrides = this.overrides.filter((o) => o.id !== id);
	}

	suppressionsFor(trainingId: string) {
		return this.suppressions.filter((s) => s.trainingId === trainingId);
	}

	overridesFor(trainingId: string) {
		return this.overrides.filter((o) => o.trainingId === trainingId);
	}
}

export const store = new TrainingStore();

// ---------------------------------------------------------------------------
// Rendering — one renderer for preview and delivery (ALE-309).

const TOKEN = /\{\{\s*([a-zA-Z]+)\s*\}\}/g;
const KNOWN_TOKENS = new Set(["title", "date", "startTime", "endTime"]);

export function formatLongDate(date: string) {
	return dayjs(date).format("dddd D MMMM");
}

export function renderCopy(
	source: string,
	context: { title: string; date: string; startTime: string; endTime: string },
) {
	return source.replace(TOKEN, (_match, name: string) => {
		switch (name) {
			case "title":
				return context.title;
			case "date":
				return formatLongDate(context.date);
			case "startTime":
				return context.startTime;
			case "endTime":
				return context.endTime;
			default:
				return `{{${name}}}`;
		}
	});
}

export function validateCopy(source: string): string[] {
	const problems: string[] = [];
	if (source.trim().length === 0) problems.push("Message cannot be empty.");
	for (const match of source.matchAll(TOKEN)) {
		if (!KNOWN_TOKENS.has(match[1]!)) {
			problems.push(`Unknown token {{${match[1]}}}.`);
		}
	}
	if (source.includes("@everyone")) {
		problems.push(
			"Do not type @everyone — copy renders literally; use the toggle to ping.",
		);
	}
	if (source.length > 2000)
		problems.push("Longer than Discord's 2,000 characters.");
	return problems;
}

export function renderMessage(
	source: string,
	everyone: boolean,
	context: { title: string; date: string; startTime: string; endTime: string },
) {
	const body = renderCopy(source, context);
	return everyone ? `@everyone\n${body}` : body;
}

export const HOLIDAY_COPY = {
	day_before: (holiday: string) =>
		`@everyone\nHeads up! Tomorrow is ${holiday} (a bank holiday), so there will be no training. Enjoy your day off!`,
	same_day: (holiday: string) =>
		`@everyone\nReminder: today is ${holiday} (a bank holiday), so there will be no training. See you next time!`,
};

// ---------------------------------------------------------------------------
// Projection — Training × dates → Training Occurrences with ALE-308 precedence.

function inRange(date: string, from: string, to: string) {
	return date >= from && date <= to;
}

function rangesOverlap(
	a: { from: string; to: string },
	b: { from: string; to: string },
) {
	return a.from <= b.to && b.from <= a.to;
}

export function formatRange(from: string, to: string) {
	if (from === to) return dayjs(from).format("ddd D MMM");
	return `${dayjs(from).format("D MMM")} – ${dayjs(to).format("D MMM YYYY")}`;
}

export function holidayOn(date: string) {
	return HOLIDAYS.find((holiday) => holiday.date === date);
}

function occurrenceDates(training: Training, start: Dayjs, end: Dayjs) {
	const dates: string[] = [];
	if (training.schedule.type === "one_off") {
		const date = dayjs(training.schedule.date);
		if (!date.isBefore(start, "day") && date.isBefore(end, "day")) {
			dates.push(date.format(DATE_FORMAT));
		}
		return dates;
	}
	let cursor = start.startOf("day");
	while (cursor.day() !== training.schedule.weekday)
		cursor = cursor.add(1, "day");
	while (cursor.isBefore(end, "day")) {
		dates.push(cursor.format(DATE_FORMAT));
		cursor = cursor.add(1, "week");
	}
	return dates;
}

export function resolveOccurrence(
	training: Training,
	date: string,
): Occurrence {
	const holiday = holidayOn(date);
	const suppression = store
		.suppressionsFor(training.id)
		.find((s) => inRange(date, s.from, s.to));
	const override = store
		.overridesFor(training.id)
		.find((o) => inRange(date, o.from, o.to));

	let decision: Decision = "default";
	if (holiday) decision = "bank_holiday";
	else if (!training.enabled) decision = "disabled";
	else if (suppression) decision = "suppressed";
	else if (override) decision = "overridden";

	const titleSource = override?.title ?? training.title;
	const messageSource = override?.message ?? training.message;
	const context = {
		title: "",
		date,
		startTime: training.schedule.startTime,
		endTime: training.schedule.endTime,
	};
	const title = renderCopy(titleSource, context);
	const rendered = renderMessage(messageSource, training.everyone, {
		...context,
		title,
	});
	const past = date < TODAY;
	const willPost = decision === "default" || decision === "overridden";
	let delivery = store.deliveries.find(
		(d) => d.trainingId === training.id && d.date === date,
	);
	if (past && !delivery) {
		delivery = willPost
			? {
					trainingId: training.id,
					date,
					state: "delivered",
					messageId: `14${date.replaceAll("-", "").slice(2)}…`,
					threadId: `14${date.replaceAll("-", "").slice(2)}…`,
					at: `${date}T${training.schedule.startTime}:03Z`,
				}
			: {
					trainingId: training.id,
					date,
					state: "skipped",
					reason: decisionLabel(decision, holiday),
				};
	}

	return {
		key: `${training.id}@${date}`,
		training,
		date,
		startTime: training.schedule.startTime,
		endTime: training.schedule.endTime,
		decision,
		holiday,
		suppression: decision === "suppressed" ? suppression : undefined,
		override,
		title,
		messageSource,
		rendered,
		threadName: title,
		willPost,
		past,
		delivery,
	};
}

export function occurrencesBetween(start: Date | string, end: Date | string) {
	const from = dayjs(start);
	const to = dayjs(end);
	const result: Occurrence[] = [];
	for (const training of store.trainings) {
		for (const date of occurrenceDates(training, from, to)) {
			result.push(resolveOccurrence(training, date));
		}
	}
	return result.sort((a, b) =>
		`${a.date} ${a.startTime}`.localeCompare(`${b.date} ${b.startTime}`),
	);
}

export function upcomingOccurrences(training: Training, count: number) {
	const dates = occurrenceDates(
		training,
		dayjs(TODAY),
		dayjs(TODAY).add(26, "week"),
	).slice(0, count);
	return dates.map((date) => resolveOccurrence(training, date));
}

export function announcementsBetween(start: Date | string, end: Date | string) {
	const from = dayjs(start);
	const to = dayjs(end);
	const result: HolidayAnnouncement[] = [];
	for (const holiday of HOLIDAYS) {
		const sameDay = dayjs(holiday.date);
		const dayBefore = sameDay.subtract(1, "day");
		for (const [phase, day] of [
			["day_before", dayBefore],
			["same_day", sameDay],
		] as const) {
			if (day.isBefore(from, "day") || !day.isBefore(to, "day")) continue;
			const date = day.format(DATE_FORMAT);
			result.push({
				key: `holiday-${phase}@${date}`,
				date,
				holiday,
				phase,
				rendered: HOLIDAY_COPY[phase](holiday.name),
				past: date < TODAY,
				delivery:
					date < TODAY
						? {
								trainingId: "holiday",
								date,
								state: "delivered",
								messageId: `13${date.replaceAll("-", "").slice(2)}…`,
							}
						: undefined,
			});
		}
	}
	return result;
}

// ---------------------------------------------------------------------------
// Labels shared by variants.

export function decisionLabel(decision: Decision, holiday?: Holiday) {
	switch (decision) {
		case "bank_holiday":
			return holiday ? `Bank holiday — ${holiday.name}` : "Bank holiday";
		case "disabled":
			return "Training disabled";
		case "suppressed":
			return "Suppressed";
		case "overridden":
			return "Override copy";
		default:
			return "Default copy";
	}
}

export const DELIVERY_LABEL = {
	delivered: "Delivered",
	thread_failed: "Posted, thread failed",
	message_uncertain: "Uncertain",
	blocked: "Blocked",
	missed: "Missed",
	skipped: "Skipped",
} satisfies Record<DeliveryState, string>;

export type Status = Decision | DeliveryState;

/** Status token used for CSS classes across variants. */
export function statusOf(occurrence: Occurrence): Status {
	if (occurrence.past && occurrence.delivery) return occurrence.delivery.state;
	return occurrence.decision;
}

export const STATUS_LABEL = {
	default: "Scheduled",
	overridden: "Override",
	suppressed: "Suppressed",
	disabled: "Disabled",
	bank_holiday: "Bank holiday",
	...DELIVERY_LABEL,
} satisfies Record<Status, string>;

export function scheduleLabel(training: Training) {
	const { schedule } = training;
	if (schedule.type === "one_off") {
		return `Once · ${dayjs(schedule.date).format("ddd D MMM YYYY")} · ${schedule.startTime}`;
	}
	return `Every ${WEEKDAYS[schedule.weekday]} · ${schedule.startTime}`;
}

export function today() {
	return dayjs(TODAY);
}
