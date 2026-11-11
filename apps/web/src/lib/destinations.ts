/**
 * Attendee-facing destination presentation (ALE-440/ALE-442).
 *
 * Pure helpers over the destination facts every workshop read carries. A
 * saved destination is exactly one of:
 *
 *   - manual text (`destinationText`): what staff typed in the destination
 *     input without choosing a suggestion, shown beside the familiar label
 *     and linked to an ordinary Maps search; or
 *   - a place selected from Google venue search, stored as its Place ID
 *     only. No Google text (and so no Google attribution) ever reaches an
 *     attendee surface: the label names the place, and directions link to it
 *     by `destination_place_id`.
 *
 * Legacy rows have neither and keep their short venue label only — nothing
 * here fabricates a place for unreviewed text.
 */

/** The destination facts a workshop read carries (all optional/nullable). */
export interface DestinationFacts {
	destinationText?: string | null;
	destinationProvider?: "google" | null;
	destinationPlaceId?: string | null;
}

const trimmed = (value: string | null | undefined) =>
	value?.trim() ? value.trim() : undefined;

const selectedPlaceId = (workshop: DestinationFacts) =>
	workshop.destinationProvider === "google"
		? trimmed(workshop.destinationPlaceId)
		: undefined;

/**
 * The recognizable destination detail to show beside the familiar venue
 * label: the manual text, as one line. Empty for a selected place (no Google
 * text is stored) and for legacy rows.
 */
export function destinationLines(workshop: DestinationFacts): string[] {
	const text = trimmed(workshop.destinationText);
	return text ? [text] : [];
}

/**
 * The external directions link for an attendee, or `undefined` when there is
 * nothing useful to link to.
 *
 * A selected place links Maps directions to its Place ID, named by the
 * domain's short `label`; manual text builds a Maps search for exactly that
 * text. A legacy label-only row gets no link.
 */
export function directionsHref(
	workshop: DestinationFacts,
	label?: string | null,
): string | undefined {
	const placeId = selectedPlaceId(workshop);
	if (placeId) {
		const destination = trimmed(label) ?? "";
		return `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(destination)}&destination_place_id=${encodeURIComponent(placeId)}`;
	}

	const text = trimmed(workshop.destinationText);
	if (!text) return undefined;
	return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(text)}`;
}

/** The hidden destination controls `destination-input.svelte` submits. */
export interface DestinationFields {
	/** The manual text, exactly as typed; empty when a place is selected. */
	destination_text: string;
	/** ALE-442: the selected Google Place ID; empty for a manual destination. */
	destination_place_id: string;
}

/**
 * The destination controls as Phoenix request fields: both keys are sent, so
 * an emptied control clears the saved value (`null`) rather than keeping it.
 * A destination is a place or text, never both: a selected Place ID sends no
 * text.
 */
export function destinationBody(fields: DestinationFields) {
	const placeId = fields.destination_place_id.trim() || null;
	return {
		destinationText: placeId ? null : fields.destination_text.trim() || null,
		destinationPlaceId: placeId,
	};
}

/** A saved destination as the controls' values, for prefilling an edit form. */
export function destinationValues(
	workshop: DestinationFacts,
): DestinationFields {
	const placeId = selectedPlaceId(workshop);
	return {
		destination_text: placeId ? "" : (workshop.destinationText ?? ""),
		destination_place_id: placeId ?? "",
	};
}
