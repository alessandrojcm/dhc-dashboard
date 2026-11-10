/**
 * Attendee-facing destination presentation (ALE-440).
 *
 * Pure helpers over the destination facts every workshop read carries. A
 * manually supplied link was already validated by Phoenix as a supported
 * HTTPS Maps destination; when there is none, the saved name/address facts
 * build an ordinary Maps search. Legacy rows have no facts and keep their
 * short venue label only — nothing here fabricates a place for unreviewed
 * text.
 */

/** The destination facts a workshop read carries (all optional/nullable). */
export interface DestinationFacts {
	destinationName?: string | null;
	destinationAddress?: string | null;
	directionsUrl?: string | null;
}

const trimmed = (value: string | null | undefined) =>
	value?.trim() ? value.trim() : undefined;

/**
 * The recognizable destination detail lines to show beside the familiar
 * venue label: the name, then the address. Empty when the row has no
 * destination details.
 */
export function destinationLines(workshop: DestinationFacts): string[] {
	return [
		trimmed(workshop.destinationName),
		trimmed(workshop.destinationAddress),
	].filter((line): line is string => line !== undefined);
}

/**
 * The external directions link for an attendee, or `undefined` when there is
 * nothing useful to link to.
 *
 * The manually supplied Maps link wins; otherwise the destination name and
 * address build a Maps search. A directions link alone (no name/address) is
 * still a usable destination.
 */
export function directionsHref(workshop: DestinationFacts): string | undefined {
	const manual = trimmed(workshop.directionsUrl);
	if (manual) return manual;

	const query = destinationLines(workshop).join(", ");
	if (!query) return undefined;

	return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(query)}`;
}

/** The destination controls `destination-input.svelte` submits. */
export interface DestinationFields {
	destination_name: string;
	destination_address: string;
	directions_url: string;
}

/**
 * The destination controls as Phoenix request fields: every key is sent, so
 * an emptied control clears the saved value (`null`) rather than keeping it.
 */
export function destinationBody(fields: DestinationFields) {
	return {
		destinationName: fields.destination_name.trim() || null,
		destinationAddress: fields.destination_address.trim() || null,
		directionsUrl: fields.directions_url.trim() || null,
	};
}

/** A saved destination as the controls' values, for prefilling an edit form. */
export function destinationValues(
	workshop: DestinationFacts,
): DestinationFields {
	return {
		destination_name: workshop.destinationName ?? "",
		destination_address: workshop.destinationAddress ?? "",
		directions_url: workshop.directionsUrl ?? "",
	};
}
