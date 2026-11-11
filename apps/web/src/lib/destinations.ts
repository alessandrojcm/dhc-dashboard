/**
 * Attendee-facing destination presentation (ALE-440).
 *
 * Pure helpers over the destination facts every workshop read carries. A
 * manually supplied link was already validated by Phoenix as a supported
 * HTTPS Maps destination; when there is none, the saved name/address facts
 * build an ordinary Maps search. Legacy rows have no facts and keep their
 * short venue label only — nothing here fabricates a place for unreviewed
 * text.
 *
 * ALE-442: a place selected from Google venue search is stored as its Place
 * ID only. The destination name and address are always staff-typed, so no
 * Google text (and no Google attribution) ever reaches an attendee surface.
 * A selected place's directions link is a Maps directions URL naming the
 * place (`destination_place_id`) beside the staff text, or the short label
 * when there is none.
 */

/** The destination facts a workshop read carries (all optional/nullable). */
export interface DestinationFacts {
	destinationName?: string | null;
	destinationAddress?: string | null;
	directionsUrl?: string | null;
	destinationProvider?: "google" | null;
	destinationPlaceId?: string | null;
}

const trimmed = (value: string | null | undefined) =>
	value?.trim() ? value.trim() : undefined;

/**
 * The recognizable destination detail lines to show beside the familiar
 * venue label: the staff-typed name, then the address. Empty when the row has
 * no destination details.
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
 * The manually supplied Maps link wins; a selected place links Maps
 * directions to its Place ID, named by the staff text or else the domain's
 * short `label`; otherwise the destination name and address build a Maps
 * search. A legacy label-only row gets no link.
 */
export function directionsHref(
	workshop: DestinationFacts,
	label?: string | null,
): string | undefined {
	const manual = trimmed(workshop.directionsUrl);
	if (manual) return manual;

	const text = destinationLines(workshop).join(", ");
	const placeId = selectedPlaceId(workshop);
	if (placeId) {
		const destination = text || trimmed(label) || "";
		return `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(destination)}&destination_place_id=${encodeURIComponent(placeId)}`;
	}

	if (!text) return undefined;
	return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(text)}`;
}

const selectedPlaceId = (workshop: DestinationFacts) =>
	workshop.destinationProvider === "google"
		? trimmed(workshop.destinationPlaceId)
		: undefined;

/** The destination controls `destination-input.svelte` submits. */
export interface DestinationFields {
	destination_name: string;
	destination_address: string;
	directions_url: string;
	/** ALE-442: the selected Google Place ID; empty for a manual destination. */
	destination_place_id: string;
}

/**
 * The destination controls as Phoenix request fields: every key is sent, so
 * an emptied control clears the saved value (`null`) rather than keeping it,
 * and the selected Place ID always travels beside the staff text (Phoenix
 * drops a place a text edit does not resend).
 */
export function destinationBody(fields: DestinationFields) {
	return {
		destinationName: fields.destination_name.trim() || null,
		destinationAddress: fields.destination_address.trim() || null,
		directionsUrl: fields.directions_url.trim() || null,
		destinationPlaceId: fields.destination_place_id.trim() || null,
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
		destination_place_id: selectedPlaceId(workshop) ?? "",
	};
}
