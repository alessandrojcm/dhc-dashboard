/**
 * ALE-390: how the door view words and filters Phoenix's door read model.
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
