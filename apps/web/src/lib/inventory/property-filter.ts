export type PropertyFilterValue = {
	definitionId: string;
	value: string;
};

/**
 * Encodes the catalog/operator `property` query param:
 * comma-separated `definitionId:value` pairs. Empty values are omitted.
 */
export function encodePropertyFilter(
	values: readonly PropertyFilterValue[],
): string | undefined {
	const pairs = values.flatMap(({ definitionId, value }) => {
		const trimmed = value.trim();
		if (!definitionId || !trimmed) return [];
		return [`${definitionId}:${trimmed}`];
	});
	return pairs.length > 0 ? pairs.join(",") : undefined;
}

export function propertyFilterEntries(
	values: Record<string, string>,
): PropertyFilterValue[] {
	return Object.entries(values).map(([definitionId, value]) => ({
		definitionId,
		value,
	}));
}
