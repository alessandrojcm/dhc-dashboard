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
 * ALE-442: a destination selected from Google venue search also carries its
 * Place ID and the credits Google requires beside it. Its directions link is
 * a Maps directions URL naming the place (`destination_place_id`), and it is
 * shown with Google Maps attribution (`destinationAttribution`).
 */
import * as v from "valibot";

/** A third-party credit Google returned with a selected place. */
export interface DestinationCredit {
	provider: string;
	providerUri: string | null;
}

/** The destination facts a workshop read carries (all optional/nullable). */
export interface DestinationFacts {
	destinationName?: string | null;
	destinationAddress?: string | null;
	directionsUrl?: string | null;
	destinationProvider?: "google" | null;
	destinationPlaceId?: string | null;
	destinationAttributions?: DestinationCredit[] | null;
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

	const placeId = selectedPlaceId(workshop);
	if (placeId) {
		return `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(query)}&destination_place_id=${encodeURIComponent(placeId)}`;
	}

	return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(query)}`;
}

const selectedPlaceId = (workshop: DestinationFacts) =>
	workshop.destinationProvider === "google"
		? trimmed(workshop.destinationPlaceId)
		: undefined;

/**
 * The attribution to show beside a Google-selected destination's name and
 * address — Google Maps plus any third-party credits — or `undefined` for a
 * manual destination, which must not be attributed to Google.
 */
export function destinationAttribution(
	workshop: DestinationFacts,
): { credits: DestinationCredit[] } | undefined {
	if (!selectedPlaceId(workshop) || destinationLines(workshop).length === 0)
		return undefined;
	return { credits: workshop.destinationAttributions ?? [] };
}

/** The destination controls `destination-input.svelte` submits. */
export interface DestinationFields {
	destination_name: string;
	destination_address: string;
	directions_url: string;
	/** ALE-442: the selected Google Place ID; empty for a manual destination. */
	destination_place_id: string;
	/** ALE-442: the selection's credits, as a JSON array (hidden control). */
	destination_attributions: string;
}

const CreditsSchema = v.array(
	v.object({
		provider: v.pipe(v.string(), v.nonEmpty(), v.maxLength(200)),
		providerUri: v.nullable(v.pipe(v.string(), v.maxLength(2048))),
	}),
);

/**
 * The credits a hidden control carries. Anything that is not a credit list
 * is no credits; Phoenix validates them again with the selection.
 */
export function parseCredits(json: string): DestinationCredit[] {
	if (!json.trim()) return [];
	try {
		const parsed = v.safeParse(CreditsSchema, JSON.parse(json));
		return parsed.success ? parsed.output : [];
	} catch {
		return [];
	}
}

/**
 * The destination controls as Phoenix request fields: every key is sent, so
 * an emptied control clears the saved value (`null`) rather than keeping it.
 */
export function destinationBody(fields: DestinationFields) {
	const placeId = fields.destination_place_id.trim() || null;
	return {
		destinationName: fields.destination_name.trim() || null,
		destinationAddress: fields.destination_address.trim() || null,
		directionsUrl: fields.directions_url.trim() || null,
		destinationPlaceId: placeId,
		destinationAttributions: placeId
			? parseCredits(fields.destination_attributions)
			: [],
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
		destination_attributions: selectedPlaceId(workshop)
			? JSON.stringify(workshop.destinationAttributions ?? [])
			: "",
	};
}
