// PROTOTYPE — throwaway (ALE-372). In-memory Beginners' Workshop fixtures shared by
// every screen and variant. Nothing here talks to Phoenix; reload to reset.
// Vocabulary follows CONTEXT.md: Beginners' Workshop, Intake, Batch, Seat Hold,
// Payment Cutoff, Carried Fee, Deferral, Fast-track, Withdrawal, Attendance
// Finalisation, Beginners' Workshop Staff, Intake Email, Invitable.
import dayjs, { type Dayjs } from "dayjs";
import { toast } from "svelte-sonner";
import type { RichTextDocument } from "#lib/components/ui/rich-text-editor/index.js";

/** Fixture clock: Friday 9 October 2026, 18:30 Dublin time. */
export const NOW = dayjs("2026-10-09T18:30:00");

/** Fixture lookups always hit; a miss is a bug in the prototype data, so fail loudly. */
export function must<T>(value: T | undefined, what = "fixture row"): T {
	if (value === undefined) throw new Error(`PROTOTYPE: missing ${what}`);
	return value;
}

export type Standing =
	| "waiting"
	| "removed"
	| "attended"
	| "invited"
	| "joined";

export type IntakeState =
	| "contacted"
	| "paid"
	| "attended"
	| "no_show"
	| "lapsed"
	| "declined"
	| "deferred"
	| "cancelled_refunded"
	| "returned"
	| "withdrawn";

export const OPEN_STATES: IntakeState[] = ["contacted", "paid"];

export type CarriedFee = {
	status: "held" | "applied" | "spent" | "refunded" | "forfeited";
	amount: number;
	fromWorkshopId: string;
	refundFailed?: boolean;
};

export type Person = {
	id: string;
	firstName: string;
	lastName: string;
	pronouns: string;
	email: string;
	phone: string;
	dob: string;
	guardian?: { name: string; phone: string };
	medical?: string;
	registeredAt: string;
	standing: Standing;
	removedAt?: string;
	carriedFee?: CarriedFee;
	/** Fixture: why issuing an Invitation would be refused right now. */
	invitationBlock?: string;
	invitationNote?: string;
};

/** Fixture: emails that belong to a Principal, or that have a pending Invitation (ALE-371 entry checks). */
export const MEMBER_EMAILS = new Set([
	"ciaran.walsh@example.ie",
	"niamh.doyle@example.ie",
]);
export const PENDING_INVITATION_EMAILS = new Set(["jo.direct@example.ie"]);

export type EmailTypeId =
	| "contact_pay"
	| "contact_confirm"
	| "place_confirmed_paid"
	| "place_confirmed_carried"
	| "pre_workshop"
	| "rescheduled"
	| "follow_up"
	| "declined"
	| "deferred"
	| "cancelled_with_refund"
	| "withdrawn_refunded"
	| "withdrawn_forfeited"
	| "carried_fee_refunded"
	| "payment_refunded"
	| "cancelled_paid"
	| "cancelled_unpaid";

export type Placeholder =
	| "firstName"
	| "date"
	| "startTime"
	| "venue"
	| "fee"
	| "windowEnd"
	| "paymentCutoff"
	| "refundAmount";

export const PLACEHOLDERS = {
	firstName: { label: "First name", max: 40 },
	date: { label: "Date", max: 27 },
	startTime: { label: "Start time", max: 5 },
	venue: { label: "Venue", max: 80 },
	fee: { label: "Fee", max: 7 },
	windowEnd: { label: "Window end", max: 34 },
	paymentCutoff: { label: "Payment Cutoff", max: 34 },
	refundAmount: { label: "Refund amount", max: 7 },
} satisfies Record<Placeholder, { label: string; max: number }>;

const BASE: Placeholder[] = ["firstName", "date", "startTime", "venue"];

export type EmailType = {
	id: EmailTypeId;
	label: string;
	kind: "action" | "notice";
	/** Button label the app sets for action emails; not editable. */
	button?: string;
	trigger: string;
	placeholders: Placeholder[];
};

export const EMAIL_TYPES: EmailType[] = [
	{
		id: "contact_pay",
		label: "Contact — pay",
		kind: "action",
		button: "Pay for your place",
		trigger: "Intake created (Batch sent, Fast-track)",
		placeholders: [...BASE, "fee", "windowEnd", "paymentCutoff"],
	},
	{
		id: "contact_confirm",
		label: "Contact — confirm (Carried Fee)",
		kind: "action",
		button: "Confirm my place",
		trigger: "Intake created for a Carried Fee holder",
		placeholders: [...BASE, "windowEnd", "paymentCutoff"],
	},
	{
		id: "place_confirmed_paid",
		label: "Place confirmed — paid",
		kind: "action",
		button: "View my place",
		trigger: "Intake becomes paid (Stripe)",
		placeholders: [...BASE, "fee"],
	},
	{
		id: "place_confirmed_carried",
		label: "Place confirmed — Carried Fee",
		kind: "action",
		button: "View my place",
		trigger: "Intake becomes paid (confirm)",
		placeholders: BASE,
	},
	{
		id: "pre_workshop",
		label: "Pre-workshop info",
		kind: "action",
		button: "View my place",
		trigger: "At the Payment Cutoff, to every paid Intake",
		placeholders: BASE,
	},
	{
		id: "rescheduled",
		label: "Workshop rescheduled",
		kind: "action",
		button: "View my place",
		trigger: "reschedule_workshop, to every open Intake",
		placeholders: [...BASE, "paymentCutoff"],
	},
	{
		id: "follow_up",
		label: "Follow-up",
		kind: "notice",
		trigger: "10:00 the morning after Attendance Finalisation",
		placeholders: ["firstName", "date"],
	},
	{
		id: "declined",
		label: "Declined",
		kind: "notice",
		trigger: "decline",
		placeholders: ["firstName", "date"],
	},
	{
		id: "deferred",
		label: "Deferred",
		kind: "notice",
		trigger: "defer; correct_attendance no-show → deferred",
		placeholders: ["firstName", "date"],
	},
	{
		id: "cancelled_with_refund",
		label: "Cancelled with refund",
		kind: "notice",
		trigger: "cancel_with_refund",
		placeholders: ["firstName", "date", "refundAmount"],
	},
	{
		id: "withdrawn_refunded",
		label: "Withdrawn — refunded",
		kind: "notice",
		trigger: "withdraw (refund)",
		placeholders: ["firstName", "refundAmount"],
	},
	{
		id: "withdrawn_forfeited",
		label: "Withdrawn — forfeited",
		kind: "notice",
		trigger: "withdraw (forfeit)",
		placeholders: ["firstName"],
	},
	{
		id: "carried_fee_refunded",
		label: "Carried Fee refunded",
		kind: "notice",
		trigger: "refund_carried_fee",
		placeholders: ["firstName", "refundAmount"],
	},
	{
		id: "payment_refunded",
		label: "Payment refunded",
		kind: "notice",
		trigger: "Automatic refund (late payment, policy failure)",
		placeholders: ["firstName", "date", "refundAmount"],
	},
	{
		id: "cancelled_paid",
		label: "Workshop cancelled — paid",
		kind: "notice",
		trigger: "cancel_workshop, to each deferred Intake",
		placeholders: ["firstName", "date"],
	},
	{
		id: "cancelled_unpaid",
		label: "Workshop cancelled — unpaid",
		kind: "notice",
		trigger: "cancel_workshop, to each contacted Intake",
		placeholders: ["firstName", "date"],
	},
];

export const emailType = (id: EmailTypeId) =>
	must(
		EMAIL_TYPES.find((type) => type.id === id),
		`email type ${id}`,
	);

export type EmailLogEntry = { type: EmailTypeId; at: string; note?: string };
export type HistoryEntry = {
	at: string;
	actor: string;
	text: string;
	note?: string;
};

export type Intake = {
	id: string;
	workshopId: string;
	personId: string;
	state: IntakeState;
	origin: "batch" | "fast_track";
	batchNo?: number;
	paidVia?: "stripe" | "carried_fee";
	paidAt?: string;
	hold?: { expiresAt: string; status: "open" | "releasing" };
	checkedIn?: { at: string; by: string };
	refund?: {
		status: "pending" | "succeeded" | "failed";
		amount: number;
		manual?: boolean;
		automatic?: boolean;
		reason?: string;
	};
	linkGeneration: number;
	emails: EmailLogEntry[];
	history: HistoryEntry[];
	closedAt?: string;
};

export type StaffMember = { id: string; name: string; isCoach: boolean };

export type Batch = {
	no: number;
	sentAt: string;
	windowEnd: string;
	size: number;
	sentBy: string;
};

export type Workshop = {
	id: string;
	date: string;
	startTime: string;
	venue: string;
	capacity: number;
	fee: number;
	paymentCutoff: string;
	status: "scheduled" | "finalised" | "cancelled";
	coachId?: string;
	assistantIds: string[];
	batches: Batch[];
	finalisedAt?: string;
	finalisedBy?: string;
	cancelledAt?: string;
	preWorkshopSentAt?: string;
	followUpSentAt?: string;
};

export type Phase =
	| "no_batch"
	| "window_open"
	| "next_batch_ready"
	| "full"
	| "payment_closed"
	| "today_before_check_in"
	| "check_in_open"
	| "awaiting_finalisation"
	| "finalised"
	| "cancelled";

export type Viewer = "coordinator" | "assistant";

export type DialogRequest =
	| { kind: "schedule" }
	| { kind: "send_batch"; workshopId: string }
	| { kind: "fast_track"; workshopId: string }
	| { kind: "staff"; workshopId: string }
	| { kind: "settings"; workshopId: string }
	| { kind: "reschedule"; workshopId: string }
	| { kind: "cancel_workshop"; workshopId: string }
	| { kind: "finish"; workshopId: string }
	| { kind: "withdraw"; intakeId: string };

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

export const euro = (cents: number) =>
	`€${(cents / 100).toFixed(cents % 100 === 0 ? 0 : 2)}`;
export const fmtDay = (iso: string | Dayjs) => dayjs(iso).format("ddd D MMM");
export const fmtDayLong = (iso: string | Dayjs) =>
	dayjs(iso).format("dddd D MMMM YYYY");
export const fmtDayTime = (iso: string | Dayjs) =>
	dayjs(iso).format("ddd D MMM, HH:mm");
export const fmtTime = (iso: string | Dayjs) => dayjs(iso).format("HH:mm");

export function relative(iso: string | Dayjs) {
	const target = dayjs(iso);
	const minutes = target.diff(NOW, "minute");
	const abs = Math.abs(minutes);
	const unit =
		abs < 60
			? `${abs} min`
			: abs < 60 * 36
				? `${Math.round(abs / 60)} h`
				: `${Math.round(abs / (60 * 24))} days`;
	return minutes >= 0 ? `in ${unit}` : `${unit} ago`;
}

export const STATE_LABEL = {
	contacted: "Contacted",
	paid: "Paid",
	attended: "Attended",
	no_show: "No-show",
	lapsed: "Lapsed",
	declined: "Declined",
	deferred: "Deferred",
	cancelled_refunded: "Cancelled, refunded",
	returned: "Returned to Waitlist",
	withdrawn: "Withdrawn",
} satisfies Record<IntakeState, string>;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const FIRST = [
	"Aoife",
	"Cian",
	"Saoirse",
	"Darragh",
	"Niamh",
	"Oisín",
	"Ciara",
	"Fionn",
	"Róisín",
	"Eoin",
	"Sadhbh",
	"Tadhg",
	"Clodagh",
	"Rory",
	"Méabh",
	"Conor",
	"Lucía",
	"Mateusz",
	"Priya",
	"Jonas",
	"Amara",
	"Kenji",
	"Zofia",
	"Tomás",
	"Ella",
	"Rían",
	"Grace",
	"Dmitri",
	"Hannah",
	"Liam",
	"Isla",
	"Pádraig",
	"Chloe",
	"Yusuf",
	"Orla",
	"Sam",
	"Bríd",
	"Marco",
	"Eabha",
	"Felix",
];
const LAST = [
	"Byrne",
	"Ryan",
	"O'Brien",
	"Walsh",
	"Kelly",
	"Doyle",
	"Murphy",
	"Nolan",
	"Kavanagh",
	"Brennan",
	"Fitzgerald",
	"Quinn",
	"Lynch",
	"Duffy",
	"Kowalski",
	"Fernández",
	"Sharma",
	"Becker",
	"Okafor",
	"Tanaka",
	"Nowak",
	"Moran",
	"Healy",
	"Dunne",
	"Farrell",
	"Keane",
	"Power",
	"Hogan",
	"Costello",
	"Gallagher",
	"Sheridan",
];
const PRONOUNS = ["she/her", "he/him", "they/them", "he/him", "she/her"];
const MEDICAL = new Map<number, string>([
	[35, "Asthma — inhaler in bag"],
	[40, "Previous ACL reconstruction (left knee)"],
	[38, "Type 1 diabetes — may need a snack break"],
	[52, "Mild epilepsy, well controlled"],
	[64, "Shoulder dislocation 2024"],
	[81, "Asthma"],
]);
const MINORS = new Set([33, 42, 55, 70, 85, 97]);

function makePeople(): Person[] {
	return Array.from({ length: 140 }, (_, index): Person => {
		const firstName = must(FIRST[(index * 7) % FIRST.length]);
		const lastName = must(LAST[(index * 11 + 3) % LAST.length]);
		const minor = MINORS.has(index);
		return {
			id: `p${index}`,
			firstName,
			lastName,
			pronouns: must(PRONOUNS[index % PRONOUNS.length]),
			email: `${firstName}.${lastName}${index}@example.ie`
				.toLowerCase()
				.replace(/[^a-z0-9.@]/g, ""),
			phone: `+353 8${index % 10} ${String(1000000 + index * 7919).slice(0, 3)} ${String(1000 + index * 37).slice(0, 4)}`,
			dob: minor
				? `2009-${String((index % 9) + 3).padStart(2, "0")}-14`
				: `${1975 + (index % 30)}-0${(index % 9) + 1}-1${index % 9}`,
			guardian: minor
				? {
						name: `${FIRST[(index + 5) % FIRST.length]} ${lastName}`,
						phone: `+353 87 ${400 + index} ${1200 + index}`,
					}
				: undefined,
			medical: MEDICAL.get(index),
			registeredAt: dayjs("2025-01-06T10:00:00")
				.add(index * 2.3, "day")
				.toISOString(),
			standing: "waiting",
		};
	});
}

const NAMED_MEMBERS: StaffMember[] = [
	{ id: "s-ciaran", name: "Ciarán Walsh", isCoach: true },
	{ id: "s-aoife", name: "Aoife Brennan", isCoach: true },
	{ id: "s-tomas", name: "Tomás Kelly", isCoach: true },
	{ id: "s-niamh", name: "Niamh Doyle", isCoach: false },
	{ id: "s-sean", name: "Seán Murphy", isCoach: false },
	{ id: "s-roisin", name: "Róisín Hughes", isCoach: false },
	{ id: "s-alessandro", name: "Alessandro Cuppari", isCoach: false },
];
const MEMBER_FIRST = [
	"Declan",
	"Siobhán",
	"Ronan",
	"Aisling",
	"Kieran",
	"Maeve",
	"Shane",
	"Gráinne",
	"Colm",
	"Nuala",
	"Barry",
	"Deirdre",
	"Fergal",
	"Úna",
	"Killian",
	"Laoise",
	"Brendan",
	"Ailbhe",
	"Cathal",
	"Muireann",
	"Eamon",
	"Sorcha",
	"Lorcan",
	"Treasa",
	"Odhrán",
	"Fiadh",
	"Seamus",
	"Caoimhe",
	"Diarmuid",
	"Ríona",
	"Ultan",
	"Bláthnaid",
];
const MEMBER_LAST = [
	"Ahern",
	"Boyle",
	"Cronin",
	"Daly",
	"Egan",
	"Flood",
	"Geraghty",
	"Hennessy",
	"Joyce",
	"Lennon",
	"McCarthy",
	"Nugent",
];
/** Every active Member: coaches are Members too, so a coach can also assist. */
export const STAFF: StaffMember[] = [
	...NAMED_MEMBERS,
	...MEMBER_FIRST.map((first, index) => ({
		id: `s-m${index}`,
		name: `${first} ${must(MEMBER_LAST[index % MEMBER_LAST.length])}`,
		isCoach: index % 7 === 3,
	})),
].sort((a, b) => a.name.localeCompare(b.name));

/** The assigned assistant the "Assistant" viewer impersonates. */
export const ASSISTANT_ID = "s-sean";
const COORDINATOR = "Alessandro Cuppari";

const VENUE = "Pearse Street Community Hall, Dublin 2";
const VENUE_2 = "St Andrew's Resource Centre, Dublin 2";
const FEE = 6000;

type Seed = {
	person: number;
	state: IntakeState;
	batchNo?: number;
	origin?: "batch" | "fast_track";
	paidVia?: "stripe" | "carried_fee";
	paidAt?: string;
	hold?: string;
	checkedIn?: { at: string; by: string };
	refundFailed?: boolean;
};

function range(from: number, to: number) {
	return Array.from({ length: to - from + 1 }, (_, index) => from + index);
}

function workshop(
	input: Omit<Workshop, "assistantIds" | "batches"> &
		Partial<Pick<Workshop, "assistantIds" | "batches">>,
): Workshop {
	return { assistantIds: [], batches: [], ...input };
}

function buildFixtures() {
	const people = makePeople();
	const intakes: Intake[] = [];
	let seq = 0;

	const W: Workshop[] = [
		workshop({
			id: "w-sep26",
			date: "2026-09-26",
			startTime: "11:00",
			venue: VENUE,
			capacity: 16,
			fee: FEE,
			paymentCutoff: "2026-09-23T11:00:00",
			status: "finalised",
			coachId: "s-ciaran",
			assistantIds: ["s-niamh"],
			finalisedAt: "2026-09-26T13:05:00",
			finalisedBy: "Ciarán Walsh",
			preWorkshopSentAt: "2026-09-23T11:00:00",
			followUpSentAt: "2026-09-27T10:00:00",
			batches: [
				{
					no: 1,
					sentAt: "2026-09-01T19:10:00",
					windowEnd: "2026-09-08T23:59:00",
					size: 17,
					sentBy: COORDINATOR,
				},
			],
		}),
		workshop({
			id: "w-oct17",
			date: "2026-10-17",
			startTime: "11:00",
			venue: VENUE,
			capacity: 16,
			fee: FEE,
			paymentCutoff: "2026-10-14T11:00:00",
			status: "cancelled",
			coachId: "s-tomas",
			cancelledAt: "2026-10-05T09:40:00",
			batches: [
				{
					no: 1,
					sentAt: "2026-09-22T20:00:00",
					windowEnd: "2026-09-29T23:59:00",
					size: 14,
					sentBy: COORDINATOR,
				},
			],
		}),
		workshop({
			id: "w-oct09",
			date: "2026-10-09",
			startTime: "19:00",
			venue: VENUE_2,
			capacity: 16,
			fee: FEE,
			paymentCutoff: "2026-10-06T19:00:00",
			status: "scheduled",
			coachId: "s-ciaran",
			assistantIds: ["s-niamh", "s-sean"],
			preWorkshopSentAt: "2026-10-06T19:00:00",
			batches: [
				{
					no: 1,
					sentAt: "2026-09-14T19:30:00",
					windowEnd: "2026-09-21T23:59:00",
					size: 16,
					sentBy: COORDINATOR,
				},
				{
					no: 2,
					sentAt: "2026-09-22T09:15:00",
					windowEnd: "2026-09-29T23:59:00",
					size: 4,
					sentBy: COORDINATOR,
				},
			],
		}),
		workshop({
			id: "w-oct11",
			date: "2026-10-11",
			startTime: "11:00",
			venue: VENUE,
			capacity: 12,
			fee: FEE,
			paymentCutoff: "2026-10-08T11:00:00",
			status: "scheduled",
			coachId: "s-aoife",
			preWorkshopSentAt: "2026-10-08T11:00:00",
			batches: [
				{
					no: 1,
					sentAt: "2026-09-20T18:00:00",
					windowEnd: "2026-09-27T23:59:00",
					size: 13,
					sentBy: COORDINATOR,
				},
			],
		}),
		workshop({
			id: "w-oct24",
			date: "2026-10-24",
			startTime: "11:00",
			venue: VENUE,
			capacity: 16,
			fee: FEE,
			paymentCutoff: "2026-10-21T11:00:00",
			status: "scheduled",
			coachId: "s-tomas",
			batches: [
				{
					no: 1,
					sentAt: "2026-10-01T19:00:00",
					windowEnd: "2026-10-08T23:59:00",
					size: 16,
					sentBy: COORDINATOR,
				},
			],
		}),
		workshop({
			id: "w-nov07",
			date: "2026-11-07",
			startTime: "11:00",
			venue: VENUE,
			capacity: 16,
			fee: FEE,
			paymentCutoff: "2026-11-04T11:00:00",
			status: "scheduled",
			coachId: "s-ciaran",
			assistantIds: ["s-sean"],
			batches: [
				{
					no: 1,
					sentAt: "2026-10-06T20:00:00",
					windowEnd: "2026-10-13T23:59:00",
					size: 16,
					sentBy: COORDINATOR,
				},
			],
		}),
		workshop({
			id: "w-nov28",
			date: "2026-11-28",
			startTime: "11:00",
			venue: VENUE,
			capacity: 16,
			fee: 6500,
			paymentCutoff: "2026-11-25T11:00:00",
			status: "scheduled",
		}),
	];

	const add = (workshopId: string, seed: Seed) => {
		const w = must(W.find((candidate) => candidate.id === workshopId));
		const batch = w.batches.find(
			(candidate) => candidate.no === (seed.batchNo ?? 1),
		);
		const contactedAt =
			batch?.sentAt ?? dayjs(w.date).subtract(20, "day").toISOString();
		const paidVia =
			seed.paidVia ??
			([
				"paid",
				"attended",
				"no_show",
				"deferred",
				"cancelled_refunded",
			].includes(seed.state)
				? "stripe"
				: undefined);
		const paidAt =
			seed.paidAt ??
			(paidVia
				? dayjs(contactedAt)
						.add(1 + (seed.person % 4), "day")
						.add(seed.person % 7, "hour")
						.toISOString()
				: undefined);
		const emails: EmailLogEntry[] = [
			{
				type:
					paidVia === "carried_fee" || seed.paidVia === "carried_fee"
						? "contact_confirm"
						: "contact_pay",
				at: contactedAt,
			},
		];
		if (paidAt)
			emails.push({
				type:
					paidVia === "carried_fee"
						? "place_confirmed_carried"
						: "place_confirmed_paid",
				at: paidAt,
			});
		if (
			w.preWorkshopSentAt &&
			paidAt &&
			dayjs(paidAt).isBefore(w.preWorkshopSentAt) &&
			["paid", "attended", "no_show"].includes(seed.state)
		)
			emails.push({ type: "pre_workshop", at: w.preWorkshopSentAt });
		if (seed.state === "attended" && w.followUpSentAt)
			emails.push({ type: "follow_up", at: w.followUpSentAt });
		if (seed.state === "declined")
			emails.push({
				type: "declined",
				at: dayjs(contactedAt).add(2, "day").toISOString(),
			});
		if (seed.state === "deferred" && w.status === "cancelled")
			emails.push({
				type: "cancelled_paid",
				at: w.cancelledAt ?? NOW.toISOString(),
			});
		else if (seed.state === "deferred")
			emails.push({
				type: "deferred",
				at: dayjs(paidAt).add(3, "day").toISOString(),
			});
		if (seed.state === "returned" && w.status === "cancelled")
			emails.push({
				type: "cancelled_unpaid",
				at: w.cancelledAt ?? NOW.toISOString(),
			});
		if (seed.state === "cancelled_refunded")
			emails.push({
				type: "cancelled_with_refund",
				at: dayjs(paidAt).add(4, "day").toISOString(),
			});

		const history: HistoryEntry[] = [
			{
				at: contactedAt,
				actor: COORDINATOR,
				text:
					seed.origin === "fast_track"
						? "Fast-tracked"
						: `Contacted in Batch ${seed.batchNo ?? 1}`,
			},
		];
		if (paidAt)
			history.push({
				at: paidAt,
				actor:
					paidVia === "carried_fee"
						? `${people[seed.person]?.firstName} (Intake page)`
						: "Stripe",
				text: paidVia === "carried_fee" ? "Confirmed with Carried Fee" : "Paid",
			});
		if (seed.state === "declined")
			history.push({
				at: dayjs(contactedAt).add(2, "day").toISOString(),
				actor: COORDINATOR,
				text: "Declined",
				note: "Replied: can't make that date",
			});
		if (seed.state === "cancelled_refunded")
			history.push({
				at: dayjs(paidAt).add(4, "day").toISOString(),
				actor: COORDINATOR,
				text: "Cancelled with refund",
				note: "Moving abroad for work",
			});

		intakes.push({
			id: `i${seq++}`,
			workshopId,
			personId: `p${seed.person}`,
			state: seed.state,
			origin: seed.origin ?? "batch",
			batchNo: seed.origin === "fast_track" ? undefined : (seed.batchNo ?? 1),
			paidVia,
			paidAt,
			hold: seed.hold ? { expiresAt: seed.hold, status: "open" } : undefined,
			checkedIn: seed.checkedIn,
			refund:
				seed.state === "cancelled_refunded"
					? {
							status: seed.refundFailed ? "failed" : "succeeded",
							amount: FEE,
							reason: seed.refundFailed
								? "Stripe: card account closed (charge_expired_for_refund)"
								: undefined,
						}
					: undefined,
			linkGeneration: 1,
			emails,
			history,
			closedAt: OPEN_STATES.includes(seed.state)
				? undefined
				: dayjs(paidAt ?? contactedAt)
						.add(3, "day")
						.toISOString(),
		});
	};

	// Finalised, 26 Sep: 14 attended, 2 no-shows, 1 declined.
	for (const p of range(0, 13))
		add("w-sep26", { person: p, state: "attended" });
	for (const p of [14, 15]) add("w-sep26", { person: p, state: "no_show" });
	add("w-sep26", { person: 16, state: "declined" });
	for (const p of [0, 1, 2]) must(people[p]).standing = "invited";
	for (const p of range(3, 13)) must(people[p]).standing = "attended";
	// Another officer invited p5 a moment ago: this console's Invite click is refused.
	must(people[5]).invitationBlock = ":already_invited";
	// p4's Invitation was deleted (the only revoke), so they are Invitable again.
	must(people[4]).invitationNote =
		"Previous Invitation deleted 3 Oct — Invitable again";
	for (const p of [14, 15])
		Object.assign(must(people[p]), {
			standing: "removed",
			removedAt: "2026-09-26T23:59:00",
		});

	// Cancelled, 17 Oct: paid people deferred (Carried Fee held), contacted returned.
	for (const p of range(17, 26))
		add("w-oct17", { person: p, state: "deferred" });
	for (const p of range(27, 30))
		add("w-oct17", { person: p, state: "returned" });
	for (const p of range(17, 26))
		must(people[p]).carriedFee = {
			status: "held",
			amount: FEE,
			fromWorkshopId: "w-oct17",
		};

	// Today, 9 Oct 19:00: full, 7 already checked in.
	const checkedIn = new Set([31, 32, 34, 36, 37, 39, 41]);
	for (const p of range(31, 44))
		add("w-oct09", {
			person: p,
			state: "paid",
			checkedIn: checkedIn.has(p)
				? {
						at: `2026-10-09T18:${String(5 + (p % 20)).padStart(2, "0")}:00`,
						by: p % 2 ? "Niamh Doyle" : "Ciarán Walsh",
					}
				: undefined,
		});
	for (const p of [45, 46])
		add("w-oct09", { person: p, state: "paid", batchNo: 2 });
	for (const p of [47, 48])
		add("w-oct09", { person: p, state: "returned", batchNo: 2 });

	// Payment closed, Sun 11 Oct: 11 paid, 1 lapsed, 1 cancelled with a failed refund.
	for (const p of range(49, 59)) add("w-oct11", { person: p, state: "paid" });
	add("w-oct11", { person: 60, state: "lapsed" });
	add("w-oct11", {
		person: 61,
		state: "cancelled_refunded",
		refundFailed: true,
	});
	Object.assign(must(people[60]), {
		standing: "removed",
		removedAt: "2026-10-08T11:00:00",
	});

	// Batch 1 window ended, 24 Oct: 12 paid, 2 contacted (can still pay), 1 declined, 1 deferred.
	for (const p of range(62, 73)) add("w-oct24", { person: p, state: "paid" });
	for (const p of [74, 75]) add("w-oct24", { person: p, state: "contacted" });
	add("w-oct24", { person: 76, state: "declined" });
	add("w-oct24", { person: 77, state: "deferred" });
	must(people[77]).carriedFee = {
		status: "held",
		amount: FEE,
		fromWorkshopId: "w-oct24",
	};

	// Batch 1 window open, 7 Nov: Carried Fee holders from the cancelled workshop confirm.
	for (const p of [17, 18, 21, 22])
		add("w-nov07", { person: p, state: "paid", paidVia: "carried_fee" });
	for (const p of [16, 27]) add("w-nov07", { person: p, state: "paid" });
	add("w-nov07", {
		person: 28,
		state: "contacted",
		hold: "2026-10-09T18:52:00",
	});
	add("w-nov07", { person: 19, state: "declined", paidVia: undefined });
	for (const p of [20, 23, 24, 25, 26])
		add("w-nov07", { person: p, state: "contacted", paidVia: undefined });
	for (const p of [29, 47]) add("w-nov07", { person: p, state: "contacted" });
	add("w-nov07", { person: 30, state: "declined" });
	for (const p of [17, 18, 21, 22])
		must(must(people[p]).carriedFee).status = "applied";
	// p30 declined by email while a Stripe checkout was open; the payment landed anyway
	// and was refunded automatically (the Intake stays closed).
	const late = must(
		intakes.find(
			(intake) => intake.workshopId === "w-nov07" && intake.personId === "p30",
		),
	);
	late.refund = {
		status: "succeeded",
		amount: FEE,
		automatic: true,
		reason: "Payment completed after the Intake closed",
	};
	late.emails.push({ type: "payment_refunded", at: "2026-10-08T21:14:00" });
	late.history.push({
		at: "2026-10-08T21:14:00",
		actor: "System",
		text: "Late payment refunded automatically",
	});
	// Fix contact email type for Carried Fee holders who haven't confirmed yet.
	for (const intake of intakes) {
		const person = must(
			people.find((candidate) => candidate.id === intake.personId),
		);
		if (
			intake.workshopId === "w-nov07" &&
			person.carriedFee &&
			intake.emails[0]
		)
			intake.emails[0].type = "contact_confirm";
	}

	return { people, intakes, workshops: W, seq };
}

// ---------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------

const p = (...content: RichTextDocument[]): RichTextDocument => ({
	type: "paragraph",
	content,
});
const t = (text: string): RichTextDocument => ({ type: "text", text });
const b = (text: string): RichTextDocument => ({
	type: "text",
	text,
	marks: [{ type: "bold" }],
});

export type Template = {
	subject: string;
	body: RichTextDocument;
	updatedAt?: string;
};

function seedTemplates() {
	const generic = (line: string) => ({
		subject: "Your Beginners' Workshop on {{date}}",
		body: {
			type: "doc",
			content: [
				p(t("Hi {{firstName}},")),
				p(t(line)),
				p(t("Dublin HEMA Club")),
			],
		},
	});
	return {
		contact_pay: {
			subject: "A place at our Beginners' Workshop on {{date}}",
			updatedAt: "2026-09-01T18:40:00",
			body: {
				type: "doc",
				content: [
					p(t("Hi {{firstName}},")),
					p(
						t(
							"Good news: you're near the top of our waitlist, and we'd love to see you at our next Beginners' Workshop on ",
						),
						b("{{date}} at {{startTime}}"),
						t(", at {{venue}}. The fee is {{fee}}."),
					),
					p(
						t("Our waitlist is long, so please pay by "),
						b("{{windowEnd}}"),
						t(
							". Payments stay open until {{paymentCutoff}}, but places go to whoever pays first, so after {{windowEnd}} your place may be offered to someone else.",
						),
					),
					p(
						t(
							"If you can't make this date, just reply to this email and we'll keep your place in the queue.",
						),
					),
					p(
						t("See you on the floor,"),
						{ type: "hardBreak" },
						t("Dublin HEMA Club"),
					),
				],
			},
		},
		contact_confirm: generic(
			"You already have a place paid for from an earlier workshop. Please confirm you can make {{date}} at {{startTime}} by {{windowEnd}}.",
		),
		place_confirmed_paid: generic(
			"Thanks for paying {{fee}}. Your place on {{date}} at {{startTime}} is confirmed.",
		),
		place_confirmed_carried: generic(
			"Your place on {{date}} at {{startTime}} is confirmed, using the fee you already paid.",
		),
		pre_workshop: generic(
			"See you on {{date}} at {{startTime}} at {{venue}}. Wear comfortable clothes and indoor runners, and bring water.",
		),
		rescheduled: generic(
			"We've had to move the workshop. It's now on {{date}} at {{startTime}} at {{venue}}. Your place carries over.",
		),
		follow_up: generic(
			"Thanks for coming on {{date}}! Your first regular class is free; come along any Tuesday or Thursday.",
		),
		declined: generic(
			"No problem, we've kept your place in the queue and we'll be in touch about a later workshop.",
		),
		deferred: generic(
			"We've kept your fee for a later workshop. You'll hear from us when the next one is scheduled.",
		),
		cancelled_with_refund: generic(
			"We've cancelled your place and refunded {{refundAmount}}. You're still in the queue.",
		),
		withdrawn_refunded: generic(
			"We've removed you from the waitlist and refunded {{refundAmount}}.",
		),
		withdrawn_forfeited: generic(
			"We've removed you from the waitlist, as you asked.",
		),
		carried_fee_refunded: generic(
			"We've refunded the {{refundAmount}} you paid. You're still in the queue.",
		),
		payment_refunded: generic(
			"Your payment of {{refundAmount}} arrived after your place had closed, so we've refunded it in full.",
		),
		cancelled_paid: generic(
			"We're sorry, we've had to cancel the workshop on {{date}}. We've kept your fee for a later one; reply if you'd prefer a refund.",
		),
		cancelled_unpaid: generic(
			"We're sorry, we've had to cancel the workshop on {{date}}. You keep your place in the queue.",
		),
	} satisfies Record<EmailTypeId, Template>;
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

type Result = { ok: true } | { ok: false; reason: string };
const refuse = (reason: string): Result => {
	toast.error(`Refused: ${reason}`);
	return { ok: false, reason };
};

class BeginnersPrototype {
	people = $state<Person[]>([]);
	intakes = $state<Intake[]>([]);
	workshops = $state<Workshop[]>([]);
	templates = $state<Record<EmailTypeId, Template>>(seedTemplates());
	viewer = $state<Viewer>("coordinator");
	dialog = $state<DialogRequest | null>(null);
	/** Intake open in the detail sheet (variants A/B). */
	sheetIntakeId = $state<string | null>(null);
	/** Named refusals from the last Invite click, shown on that person's row. */
	inviteRefusals = $state<Record<string, string>>({});
	private seq = 0;

	constructor() {
		this.reset();
	}

	reset() {
		const fixtures = buildFixtures();
		this.people = fixtures.people;
		this.intakes = fixtures.intakes;
		this.workshops = fixtures.workshops;
		this.templates = seedTemplates();
		this.seq = fixtures.seq;
		this.dialog = null;
		this.sheetIntakeId = null;
		this.inviteRefusals = {};
	}

	actor() {
		return this.viewer === "assistant" ? "Seán Murphy" : COORDINATOR;
	}

	// --- reads ---------------------------------------------------------------

	workshop(id: string) {
		return must(
			this.workshops.find((w) => w.id === id),
			`workshop ${id}`,
		);
	}
	person(id: string) {
		return must(
			this.people.find((person) => person.id === id),
			`person ${id}`,
		);
	}
	intake(id: string) {
		return must(
			this.intakes.find((intake) => intake.id === id),
			`intake ${id}`,
		);
	}
	intakesOf(workshopId: string) {
		return this.intakes.filter((intake) => intake.workshopId === workshopId);
	}
	staffName(id?: string) {
		return STAFF.find((member) => member.id === id)?.name;
	}
	openIntakeOf(personId: string) {
		return this.intakes.find(
			(intake) =>
				intake.personId === personId && OPEN_STATES.includes(intake.state),
		);
	}
	isMinorAt(person: Person, w: Workshop) {
		return dayjs(w.date).diff(dayjs(person.dob), "year") < 18;
	}
	holdLive(intake: Intake) {
		return (
			intake.hold?.status === "open" &&
			dayjs(intake.hold.expiresAt).isAfter(NOW)
		);
	}
	seats(w: Workshop) {
		const list = this.intakesOf(w.id);
		const paid = list.filter((intake) =>
			["paid", "attended", "no_show"].includes(intake.state),
		).length;
		const holds = list.filter(
			(intake) => intake.state === "contacted" && this.holdLive(intake),
		).length;
		return {
			paid,
			holds,
			free: Math.max(0, w.capacity - paid - holds),
			capacity: w.capacity,
		};
	}
	start(w: Workshop) {
		return dayjs(`${w.date}T${w.startTime}:00`);
	}
	checkInOpensAt(w: Workshop) {
		return this.start(w).subtract(1, "hour");
	}
	checkInOpen(w: Workshop) {
		return (
			w.status === "scheduled" &&
			!NOW.isBefore(this.checkInOpensAt(w)) &&
			NOW.isBefore(dayjs(w.date).endOf("day"))
		);
	}
	afterCutoff(w: Workshop) {
		return !NOW.isBefore(dayjs(w.paymentCutoff));
	}
	daysToGo(w: Workshop) {
		return this.start(w).startOf("day").diff(NOW.startOf("day"), "day");
	}
	lastBatch(w: Workshop) {
		return w.batches.at(-1);
	}
	phase(w: Workshop): Phase {
		if (w.status === "cancelled") return "cancelled";
		if (w.status === "finalised") return "finalised";
		if (this.checkInOpen(w)) return "check_in_open";
		if (dayjs(w.date).isSame(NOW, "day")) return "today_before_check_in";
		if (NOW.isAfter(dayjs(w.date).endOf("day"))) return "awaiting_finalisation";
		if (this.afterCutoff(w)) return "payment_closed";
		const last = this.lastBatch(w);
		if (!last) return "no_batch";
		if (dayjs(last.windowEnd).isAfter(NOW)) return "window_open";
		return w.capacity - this.seats(w).paid > 0 ? "next_batch_ready" : "full";
	}
	phaseLabel(w: Workshop) {
		const last = this.lastBatch(w);
		switch (this.phase(w)) {
			case "no_batch":
				return "Ready for Batch 1";
			case "window_open":
				return `Batch ${last?.no} window open until ${fmtDay(must(last).windowEnd)}`;
			case "next_batch_ready":
				return `Batch ${last?.no} window ended — Batch ${(last?.no ?? 0) + 1} ready`;
			case "full":
				return "Full — waiting for the Payment Cutoff";
			case "payment_closed":
				return "Payment closed";
			case "today_before_check_in":
				return `Today — check-in opens ${this.checkInOpensAt(w).format("HH:mm")}`;
			case "check_in_open":
				return "Today — check-in open";
			case "awaiting_finalisation":
				return "Awaiting finalisation";
			case "finalised":
				return "Finalised";
			case "cancelled":
				return "Cancelled";
		}
	}
	/** Next Batch as the system would draft it now: capacity − paid, Waitlist priority order. */
	proposal(w: Workshop) {
		if (w.status !== "scheduled" || this.afterCutoff(w)) return [];
		const size = w.capacity - this.seats(w).paid;
		if (size <= 0) return [];
		return this.people
			.filter(
				(person) =>
					person.standing === "waiting" && !this.openIntakeOf(person.id),
			)
			.sort((a, b) => a.registeredAt.localeCompare(b.registeredAt))
			.slice(0, size);
	}
	alerts(w: Workshop) {
		const out: {
			tone: "warn" | "error" | "info";
			text: string;
			intakeId?: string;
		}[] = [];
		if (w.status === "scheduled" && !w.coachId)
			out.push({ tone: "warn", text: "Unstaffed: no coach assigned" });
		for (const intake of this.intakesOf(w.id)) {
			if (intake.refund?.status === "failed")
				out.push({
					tone: "error",
					intakeId: intake.id,
					text: `Refund failed for ${this.person(intake.personId).firstName} ${this.person(intake.personId).lastName}`,
				});
		}
		if (this.phase(w) === "next_batch_ready")
			out.push({
				tone: "info",
				text: `Batch ${(this.lastBatch(w)?.no ?? 0) + 1} is ready to send`,
			});
		return out;
	}
	invitable() {
		return this.people
			.filter((person) => person.standing === "attended")
			.map((person) => {
				const intake = must(
					this.intakes.find(
						(candidate) =>
							candidate.personId === person.id &&
							candidate.state === "attended",
					),
				);
				return { person, intake, workshop: this.workshop(intake.workshopId) };
			})
			.sort((a, b) => a.workshop.date.localeCompare(b.workshop.date));
	}
	visibleWorkshops() {
		const sorted = [...this.workshops].sort((a, b) =>
			a.date.localeCompare(b.date),
		);
		if (this.viewer === "coordinator") return sorted;
		return sorted.filter(
			(w) =>
				(w.coachId === ASSISTANT_ID || w.assistantIds.includes(ASSISTANT_ID)) &&
				w.status === "scheduled",
		);
	}

	// --- effects -------------------------------------------------------------

	private email(intake: Intake, type: EmailTypeId, quiet = false) {
		intake.emails.push({ type, at: NOW.toISOString() });
		if (!quiet)
			toast(
				`📧 Queued “${emailType(type).label}” → ${this.person(intake.personId).firstName}`,
			);
	}
	private log(intake: Intake, text: string, note?: string) {
		intake.history.push({
			at: NOW.toISOString(),
			actor: this.actor(),
			text,
			note,
		});
	}
	private toWaiting(person: Person) {
		person.standing = "waiting";
		person.removedAt = undefined;
	}
	private releaseHold(intake: Intake) {
		if (intake.hold?.status === "open") intake.hold.status = "releasing";
	}
	private close(intake: Intake, state: IntakeState) {
		intake.state = state;
		intake.closedAt = NOW.toISOString();
		this.releaseHold(intake);
	}

	// --- workshop commands ---------------------------------------------------

	schedule(input: {
		date: string;
		startTime: string;
		venue: string;
		capacity: number;
		fee: number;
		cutoffDays: number;
		coachId?: string;
		assistantIds: string[];
	}) {
		const id = `w-new${this.seq++}`;
		const start = dayjs(`${input.date}T${input.startTime}:00`);
		this.workshops.push(
			workshop({
				id,
				date: input.date,
				startTime: input.startTime,
				venue: input.venue,
				capacity: input.capacity,
				fee: input.fee,
				paymentCutoff: start.subtract(input.cutoffDays, "day").toISOString(),
				status: "scheduled",
				coachId: input.coachId,
				assistantIds: input.assistantIds,
			}),
		);
		toast.success(`Scheduled Beginners' Workshop on ${fmtDay(input.date)}`);
		return id;
	}

	sendBatch(workshopId: string, windowEnd: string): Result {
		const w = this.workshop(workshopId);
		if (w.status !== "scheduled") return refuse(":not_scheduled");
		if (this.afterCutoff(w)) return refuse(":after_payment_cutoff");
		if (dayjs(windowEnd).isAfter(w.paymentCutoff))
			return refuse(":window_past_cutoff");
		const people = this.proposal(w);
		if (!people.length) return refuse(":full");
		const no = (this.lastBatch(w)?.no ?? 0) + 1;
		w.batches.push({
			no,
			sentAt: NOW.toISOString(),
			windowEnd,
			size: people.length,
			sentBy: this.actor(),
		});
		for (const person of people) {
			const intake: Intake = {
				id: `i${this.seq++}`,
				workshopId,
				personId: person.id,
				state: "contacted",
				origin: "batch",
				batchNo: no,
				linkGeneration: 1,
				emails: [],
				history: [],
			};
			this.log(intake, `Contacted in Batch ${no}`);
			this.email(
				intake,
				person.carriedFee?.status === "held"
					? "contact_confirm"
					: "contact_pay",
				true,
			);
			this.intakes.push(intake);
		}
		toast.success(`Batch ${no} sent: ${people.length} Contact emails queued`);
		return { ok: true };
	}

	fastTrack(workshopId: string, personId: string, note?: string): Result {
		const w = this.workshop(workshopId);
		const person = this.person(personId);
		if (w.status !== "scheduled") return refuse(":not_scheduled");
		if (this.openIntakeOf(personId)) return refuse(":has_open_intake");
		if (["attended", "invited", "joined"].includes(person.standing))
			return refuse(":already_attended");
		if (this.afterCutoff(w) && person.carriedFee?.status !== "held")
			return refuse(":after_payment_cutoff (only Carried Fee holders)");
		this.toWaiting(person);
		const intake: Intake = {
			id: `i${this.seq++}`,
			workshopId,
			personId,
			state: "contacted",
			origin: "fast_track",
			linkGeneration: 1,
			emails: [],
			history: [],
		};
		this.log(intake, "Fast-tracked", note);
		this.email(
			intake,
			person.carriedFee?.status === "held" ? "contact_confirm" : "contact_pay",
		);
		this.intakes.push(intake);
		return { ok: true };
	}

	/** Staff-only registration. Same email checks as public registration, but the reason is shown (ALE-371). */
	addPersonAndFastTrack(
		workshopId: string,
		input: { firstName: string; lastName: string; email: string; dob: string },
	): Result {
		const email = input.email.trim().toLowerCase();
		const reason = this.people.some((person) => person.email === email)
			? ":already_on_waitlist"
			: MEMBER_EMAILS.has(email)
				? ":email_belongs_to_member"
				: PENDING_INVITATION_EMAILS.has(email)
					? ":pending_invitation"
					: undefined;
		if (reason) return { ok: false, reason };
		const person: Person = {
			id: `p-new${this.seq++}`,
			firstName: input.firstName,
			lastName: input.lastName,
			email,
			pronouns: "",
			phone: "",
			dob: input.dob,
			registeredAt: NOW.toISOString(),
			standing: "waiting",
		};
		this.people.push(person);
		return this.fastTrack(workshopId, person.id, "Added by staff");
	}

	setStaff(
		workshopId: string,
		coachId: string | undefined,
		assistantIds: string[],
	): Result {
		const w = this.workshop(workshopId);
		if (w.status !== "scheduled") return refuse(":after_finalisation");
		w.coachId = coachId;
		w.assistantIds = assistantIds;
		toast.success("Staff updated — assigned staff get an in-app Notification");
		return { ok: true };
	}

	updateSettings(
		workshopId: string,
		input: { capacity: number; paymentCutoff: string; fee: number },
	): Result {
		const w = this.workshop(workshopId);
		const seats = this.seats(w);
		if (input.capacity < seats.paid + seats.holds)
			return refuse(":capacity_below_taken");
		if (input.fee !== w.fee && this.intakesOf(w.id).length)
			return refuse(":fee_locked");
		w.capacity = input.capacity;
		w.paymentCutoff = input.paymentCutoff;
		w.fee = input.fee;
		toast.success("Workshop updated");
		return { ok: true };
	}

	reschedule(
		workshopId: string,
		input: {
			date: string;
			startTime: string;
			venue: string;
			paymentCutoff: string;
		},
	): Result {
		const w = this.workshop(workshopId);
		if (w.status === "finalised") return refuse(":after_finalisation");
		if (w.status === "cancelled") return refuse(":already_cancelled");
		Object.assign(w, input);
		const last = this.lastBatch(w);
		if (last && dayjs(last.windowEnd).isAfter(input.paymentCutoff))
			last.windowEnd = input.paymentCutoff;
		const open = this.intakesOf(w.id).filter((intake) =>
			OPEN_STATES.includes(intake.state),
		);
		for (const intake of open) {
			this.log(intake, "Workshop rescheduled");
			this.email(intake, "rescheduled", true);
		}
		toast.success(
			`Rescheduled: ${open.length} “Workshop rescheduled” emails queued`,
		);
		return { ok: true };
	}

	cancelWorkshop(workshopId: string, note?: string): Result {
		const w = this.workshop(workshopId);
		if (w.status === "finalised") return refuse(":after_finalisation");
		if (w.status === "cancelled") return refuse(":already_cancelled");
		w.status = "cancelled";
		w.cancelledAt = NOW.toISOString();
		let deferred = 0;
		let returned = 0;
		for (const intake of this.intakesOf(w.id)) {
			const person = this.person(intake.personId);
			if (intake.state === "paid") {
				this.close(intake, "deferred");
				intake.checkedIn = undefined;
				person.carriedFee = person.carriedFee
					? { ...person.carriedFee, status: "held" }
					: { status: "held", amount: w.fee, fromWorkshopId: w.id };
				this.toWaiting(person);
				this.log(intake, "Deferred by workshop cancellation", note);
				this.email(intake, "cancelled_paid", true);
				deferred++;
			} else if (intake.state === "contacted") {
				this.close(intake, "returned");
				this.toWaiting(person);
				this.log(intake, "Returned to Waitlist by workshop cancellation", note);
				this.email(intake, "cancelled_unpaid", true);
				returned++;
			}
		}
		toast.success(
			`Cancelled: ${deferred} deferred (Carried Fee), ${returned} returned to the Waitlist`,
		);
		return { ok: true };
	}

	finish(workshopId: string): Result {
		const w = this.workshop(workshopId);
		if (w.status !== "scheduled") return refuse(":after_finalisation");
		if (!this.checkInOpen(w)) return refuse(":check_in_closed");
		let attended = 0;
		let noShow = 0;
		for (const intake of this.intakesOf(w.id)) {
			if (intake.state !== "paid") continue;
			const person = this.person(intake.personId);
			if (intake.checkedIn) {
				intake.state = "attended";
				person.standing = "attended";
				if (person.carriedFee?.status === "applied")
					person.carriedFee.status = "spent";
				attended++;
			} else {
				intake.state = "no_show";
				person.standing = "removed";
				person.removedAt = NOW.toISOString();
				if (person.carriedFee?.status === "applied")
					person.carriedFee.status = "forfeited";
				noShow++;
			}
			intake.closedAt = NOW.toISOString();
		}
		w.status = "finalised";
		w.finalisedAt = NOW.toISOString();
		w.finalisedBy = this.actor();
		toast.success(
			`Finalised: ${attended} attended, ${noShow} no-show. Follow-up emails go out at 10:00 tomorrow.`,
		);
		return { ok: true };
	}

	// --- intake commands -----------------------------------------------------

	private intakeAndPerson(intakeId: string) {
		const intake = this.intake(intakeId);
		return {
			intake,
			person: this.person(intake.personId),
			w: this.workshop(intake.workshopId),
		};
	}

	decline(intakeId: string, note?: string): Result {
		const { intake, person } = this.intakeAndPerson(intakeId);
		if (intake.state !== "contacted") return refuse(":not_allowed_in_state");
		this.close(intake, "declined");
		this.toWaiting(person);
		this.log(intake, "Declined", note);
		this.email(intake, "declined");
		return { ok: true };
	}

	defer(intakeId: string, note?: string): Result {
		const { intake, person, w } = this.intakeAndPerson(intakeId);
		if (intake.state !== "paid") return refuse(":not_allowed_in_state");
		this.close(intake, "deferred");
		intake.checkedIn = undefined;
		person.carriedFee = person.carriedFee
			? { ...person.carriedFee, status: "held" }
			: { status: "held", amount: w.fee, fromWorkshopId: w.id };
		this.toWaiting(person);
		this.log(intake, "Deferred — fee carried over", note);
		this.email(intake, "deferred");
		return { ok: true };
	}

	cancelWithRefund(intakeId: string, note?: string): Result {
		const { intake, person, w } = this.intakeAndPerson(intakeId);
		if (intake.state !== "paid") return refuse(":not_allowed_in_state");
		this.close(intake, "cancelled_refunded");
		intake.checkedIn = undefined;
		intake.refund = {
			status: "succeeded",
			amount: person.carriedFee?.amount ?? w.fee,
		};
		if (person.carriedFee?.status === "applied")
			person.carriedFee.status = "refunded";
		this.toWaiting(person);
		this.log(intake, "Cancelled with refund", note);
		this.email(intake, "cancelled_with_refund");
		return { ok: true };
	}

	withdraw(intakeId: string, refund: boolean, note?: string): Result {
		const { intake, person } = this.intakeAndPerson(intakeId);
		if (!OPEN_STATES.includes(intake.state))
			return refuse(":not_allowed_in_state");
		const wasPaid = intake.state === "paid";
		this.close(intake, wasPaid ? "withdrawn" : "declined");
		intake.checkedIn = undefined;
		if (wasPaid && refund)
			intake.refund = {
				status: "succeeded",
				amount:
					person.carriedFee?.amount ?? this.workshop(intake.workshopId).fee,
			};
		if (
			person.carriedFee &&
			["held", "applied"].includes(person.carriedFee.status)
		)
			person.carriedFee.status = refund ? "refunded" : "forfeited";
		person.standing = "removed";
		person.removedAt = NOW.toISOString();
		this.log(
			intake,
			`Withdrawn${wasPaid ? (refund ? " with refund" : ", fee forfeited") : ""}`,
			note,
		);
		this.email(
			intake,
			wasPaid || person.carriedFee
				? refund
					? "withdrawn_refunded"
					: "withdrawn_forfeited"
				: "withdrawn_forfeited",
		);
		return { ok: true };
	}

	confirm(intakeId: string): Result {
		const { intake, person, w } = this.intakeAndPerson(intakeId);
		if (intake.state !== "contacted") return refuse(":not_allowed_in_state");
		if (person.carriedFee?.status !== "held") return refuse(":no_carried_fee");
		if (this.afterCutoff(w)) return refuse(":after_payment_cutoff");
		if (this.seats(w).free <= 0) return refuse(":seat_unavailable");
		intake.state = "paid";
		intake.paidVia = "carried_fee";
		intake.paidAt = NOW.toISOString();
		person.carriedFee.status = "applied";
		this.log(intake, "Confirmed with Carried Fee (staff)");
		this.email(intake, "place_confirmed_carried");
		return { ok: true };
	}

	refundCarriedFee(personId: string, intakeId?: string): Result {
		const person = this.person(personId);
		if (
			!person.carriedFee ||
			!["held", "applied"].includes(person.carriedFee.status)
		)
			return refuse(":no_carried_fee");
		const open = intakeId ? this.intake(intakeId) : this.openIntakeOf(personId);
		if (open?.state === "paid" && open.paidVia === "carried_fee")
			return this.cancelWithRefund(open.id, "Carried Fee refunded");
		person.carriedFee.status = "refunded";
		if (open) {
			this.log(open, "Carried Fee refunded — Intake page now asks for payment");
			this.email(open, "carried_fee_refunded");
		} else toast(`📧 Queued “Carried Fee refunded” → ${person.firstName}`);
		return { ok: true };
	}

	retryRefund(intakeId: string): Result {
		const intake = this.intake(intakeId);
		if (intake.refund?.status !== "failed") return refuse(":not_failed");
		intake.refund.status = "succeeded";
		intake.refund.reason = undefined;
		this.log(intake, "Refund retried — succeeded");
		this.email(intake, "cancelled_with_refund");
		return { ok: true };
	}

	recordManualRefund(intakeId: string, note?: string): Result {
		const intake = this.intake(intakeId);
		if (intake.refund?.status !== "failed") return refuse(":not_failed");
		intake.refund = {
			...intake.refund,
			status: "succeeded",
			manual: true,
			reason: undefined,
		};
		this.log(intake, "Manual refund recorded", note);
		toast.success("Recorded as refunded (manual) — no email sent");
		return { ok: true };
	}

	resendLink(intakeId: string): Result {
		const intake = this.intake(intakeId);
		if (!OPEN_STATES.includes(intake.state)) return refuse(":intake_closed");
		const person = this.person(intake.personId);
		const type: EmailTypeId =
			intake.state === "contacted"
				? person.carriedFee?.status === "held"
					? "contact_confirm"
					: "contact_pay"
				: intake.paidVia === "carried_fee"
					? "place_confirmed_carried"
					: "place_confirmed_paid";
		this.log(intake, "Link re-sent");
		this.email(intake, type);
		return { ok: true };
	}

	rotateLink(intakeId: string): Result {
		const intake = this.intake(intakeId);
		if (!OPEN_STATES.includes(intake.state)) return refuse(":intake_closed");
		intake.linkGeneration++;
		this.log(
			intake,
			`Link rotated (generation ${intake.linkGeneration}) — old link stops working`,
		);
		const person = this.person(intake.personId);
		this.email(
			intake,
			intake.state === "contacted"
				? person.carriedFee?.status === "held"
					? "contact_confirm"
					: "contact_pay"
				: intake.paidVia === "carried_fee"
					? "place_confirmed_carried"
					: "place_confirmed_paid",
		);
		return { ok: true };
	}

	checkIn(intakeId: string): Result {
		const { intake, w } = this.intakeAndPerson(intakeId);
		if (!this.checkInOpen(w)) return refuse(":check_in_closed");
		if (intake.state !== "paid") return refuse(":not_allowed_in_state");
		intake.checkedIn = {
			at: NOW.add(Math.floor(Math.random() * 20), "minute").toISOString(),
			by: this.actor(),
		};
		this.log(intake, "Checked in");
		return { ok: true };
	}

	undoCheckIn(intakeId: string): Result {
		const { intake, w } = this.intakeAndPerson(intakeId);
		if (!this.checkInOpen(w)) return refuse(":after_finalisation");
		intake.checkedIn = undefined;
		this.log(intake, "Check-in undone");
		return { ok: true };
	}

	correctAttendance(
		intakeId: string,
		target: "attended" | "no_show" | "deferred",
		note?: string,
	): Result {
		const { intake, person, w } = this.intakeAndPerson(intakeId);
		if (this.viewer !== "coordinator")
			return refuse(":forbidden (manage only)");
		if (w.status !== "finalised") return refuse(":before_finalisation");
		if (["invited", "joined"].includes(person.standing))
			return refuse(`:already_${person.standing}`);
		if (target === "deferred" && intake.state !== "no_show")
			return refuse(":not_allowed_in_state");
		if (target === "attended" && intake.state === "no_show") {
			intake.state = "attended";
			this.toWaiting(person);
			person.standing = "attended";
			this.log(intake, "Attendance corrected: no-show → attended", note);
			if (w.followUpSentAt) this.email(intake, "follow_up");
		} else if (target === "no_show" && intake.state === "attended") {
			intake.state = "no_show";
			person.standing = "removed";
			person.removedAt = NOW.toISOString();
			this.log(intake, "Attendance corrected: attended → no-show", note);
		} else if (target === "deferred") {
			intake.state = "deferred";
			person.carriedFee = person.carriedFee
				? { ...person.carriedFee, status: "held" }
				: { status: "held", amount: w.fee, fromWorkshopId: w.id };
			this.toWaiting(person);
			this.log(intake, "Attendance corrected: no-show → deferred", note);
			this.email(intake, "deferred");
		} else return refuse(":not_allowed_in_state");
		return { ok: true };
	}

	/** Per-person, one click, no bulk (ALE-371). A refusal is shown on the row, not as a toast. */
	sendInvitation(personId: string): Result {
		const person = this.person(personId);
		const reason =
			this.viewer !== "coordinator"
				? ":forbidden (members.invite)"
				: person.standing !== "attended"
					? ":not_invitable"
					: person.invitationBlock;
		if (reason) {
			this.inviteRefusals[personId] = reason;
			// The refusal reflects a concurrent change: the row catches up.
			if (reason === ":already_invited") {
				person.standing = "invited";
				person.invitationBlock = undefined;
			}
			return { ok: false, reason };
		}
		delete this.inviteRefusals[personId];
		person.standing = "invited";
		person.invitationNote = undefined;
		toast.success(
			`Invitation sent to ${person.firstName} ${person.lastName} (inviteMember email, 7-day expiry)`,
		);
		return { ok: true };
	}

	saveTemplate(
		id: EmailTypeId,
		subject: string,
		body: RichTextDocument,
		length: number,
	): Result {
		if (length > 2000) return refuse(":too_long");
		this.templates[id] = { subject, body, updatedAt: NOW.toISOString() };
		toast.success(
			`Saved “${emailType(id).label}” — affects emails queued from now on`,
		);
		return { ok: true };
	}
}

export const proto = new BeginnersPrototype();
