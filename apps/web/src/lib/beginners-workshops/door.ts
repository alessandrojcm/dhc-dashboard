/**
 * ALE-390: how the door view words and filters Phoenix's door read model;
 * ALE-391: the Finish button and the finalised summary.
 * The check-in window and who has a seat are Phoenix's judgement
 * (`WorkshopPolicy.check_in_window/2`, `DoorView`); this module only names,
 * counts and filters them. Instants are shown on the Europe/Dublin clock.
 */
import type {
	BeginnersWorkshopDoor,
	BeginnersWorkshopDoorPerson,
} from "@dhc/api-client";
import { formatDublinInstant } from "#lib/beginners-workshops/console.js";

export type DoorFilter = "to_arrive" | "in" | "all";

const dublinTime = new Intl.DateTimeFormat("en-IE", {
	timeZone: "Europe/Dublin",
	hour: "2-digit",
	minute: "2-digit",
	hourCycle: "h23",
});

/** An instant as Dublin `HH:MM`. */
export function doorTime(iso: string): string {
	return dublinTime.format(new Date(iso));
}

/** `Ciara Byrne`, or that the person was anonymised. */
export function doorName(person: BeginnersWorkshopDoorPerson): string {
	const name = [person.firstName, person.lastName].filter(Boolean).join(" ");
	return name || "Anonymised";
}

/** The "N of M in" counter: everyone with a seat, and how many are in. */
export function doorCount(door: BeginnersWorkshopDoor) {
	const total = door.people.length;
	const checkedIn = door.people.filter((person) => person.checkedIn).length;
	return { checkedIn, total, label: `${checkedIn} of ${total} in` };
}

/**
 * The people shown: a name search looks through everyone (so a person
 * already in is still found); otherwise the To arrive / In / All filter.
 */
export function visiblePeople(
	people: BeginnersWorkshopDoorPerson[],
	filter: DoorFilter,
	search: string,
): BeginnersWorkshopDoorPerson[] {
	const query = search.trim().toLocaleLowerCase();
	if (query) {
		return people.filter((person) =>
			doorName(person).toLocaleLowerCase().includes(query),
		);
	}
	if (filter === "to_arrive") return people.filter((p) => !p.checkedIn);
	if (filter === "in") return people.filter((p) => p.checkedIn);
	return people;
}

/** What the door says about the check-in window, or `null` while it is open. */
export function windowNotice(door: BeginnersWorkshopDoor): string | null {
	switch (door.checkIn.window) {
		case "open":
			return null;
		case "before":
			return `Check-in opens ${formatDublinInstant(door.checkIn.opensAt)}`;
		case "closed":
			return "Check-in has closed";
	}
}

/** `In 18:45 · by Aoife Coach`. */
export function checkedInLine(
	checkedIn: NonNullable<BeginnersWorkshopDoorPerson["checkedIn"]>,
): string {
	return `In ${doorTime(checkedIn.at)} · by ${checkedIn.by}`;
}

/** A `tel:` link for a phone number as typed (spaces and punctuation dropped). */
export function telHref(phone: string): string {
	return `tel:${phone.replace(/[^\d+]/g, "")}`;
}

/**
 * Who becomes a no-show if the workshop finishes now: every paid person not
 * checked in (Phoenix decides it again under its lock).
 */
export function willNoShow(
	door: BeginnersWorkshopDoor,
): BeginnersWorkshopDoorPerson[] {
	return door.people.filter(
		(person) => person.state === "paid" && !person.checkedIn,
	);
}

/** Whether the door offers Finish: scheduled, and check-in has opened. */
export function canFinish(door: BeginnersWorkshopDoor): boolean {
	return door.status === "scheduled" && door.checkIn.window !== "before";
}

/** `Finish workshop (2 will be no-show)`. */
export function finishLabel(door: BeginnersWorkshopDoor): string {
	return `Finish workshop (${willNoShow(door).length} will be no-show)`;
}

/**
 * The finalised summary: `Finalised Sat 14 Nov, 20:05 by Aoife Coach` (or
 * `automatically at the end of the day`) and `12 attended · 2 no-show`.
 */
export type FinalisedSummary = { title: string; outcome: string };

export function finalisedSummary(
	finalisation: NonNullable<BeginnersWorkshopDoor["finalisation"]>,
): FinalisedSummary {
	const by = finalisation.by
		? `by ${finalisation.by}`
		: "automatically at the end of the day";
	return {
		title: `Finalised ${formatDublinInstant(finalisation.at)} ${by}`,
		outcome: `${finalisation.attended} attended · ${finalisation.noShow} no-show`,
	};
}
