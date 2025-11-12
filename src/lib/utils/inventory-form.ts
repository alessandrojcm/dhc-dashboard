/**
 * Shared utilities for inventory item forms
 */

/**
 * Builds a hierarchical display for container selection with indentation
 */
export function buildContainerHierarchy(containers: any[]) {
	const containerMap = new Map();
	const rootContainers: any[] = [];

	containers.forEach((container) => {
		containerMap.set(container.id, { ...container, children: [] });
	});

	containers.forEach((container) => {
		if (container.parent_container_id) {
			const parent = containerMap.get(container.parent_container_id);
			if (parent) {
				parent.children.push(containerMap.get(container.id));
			}
		} else {
			rootContainers.push(containerMap.get(container.id));
		}
	});

	const flattenWithIndent = (containers: any[], level = 0): any[] => {
		const result: any[] = [];
		containers.forEach((container) => {
			result.push({
				...container,
				displayName: '  '.repeat(level) + container.name,
				level
			});
			if (container.children.length > 0) {
				result.push(...flattenWithIndent(container.children, level + 1));
			}
		});
		return result;
	};

	return flattenWithIndent(rootContainers);
}

/**
 * Validates required attributes for a category
 * Returns errors object and hasErrors flag
 */
export function validateCategoryAttributes(
	categoryAttributes: any[],
	formDataAttributes: Record<string, any>
): { errors: Record<string, string>; hasErrors: boolean } {
	const errors: Record<string, string> = {};
	let hasErrors = false;

	categoryAttributes.forEach((attr) => {
		if (attr.required) {
			const value = formDataAttributes?.[attr.name];
			if (!value || value === '' || value === null || value === undefined) {
				errors[attr.name] = `${attr.label} is required`;
				hasErrors = true;
			}
		}
	});

	return { errors, hasErrors };
}

/**
 * Cleans attributes to only include non-empty values
 */
export function cleanAttributes(attributes: Record<string, any>): Record<string, any> {
	const cleaned: Record<string, any> = {};

	Object.entries(attributes).forEach(([key, value]) => {
		if (value !== null && value !== undefined && value !== '') {
			cleaned[key] = value;
		}
	});

	return cleaned;
}

/**
 * Resets attributes when category changes, preserving matching attributes
 * and initializing new ones with defaults
 */
export function resetAttributesForCategory(
	newCategory: any,
	currentAttributes: Record<string, any>
): Record<string, any> {
	const newAttributes: Record<string, any> = {};

	if (newCategory?.available_attributes && Array.isArray(newCategory.available_attributes)) {
		newCategory.available_attributes.forEach((attr: any) => {
			// Preserve existing value if it exists
			if (currentAttributes[attr.name] !== undefined) {
				newAttributes[attr.name] = currentAttributes[attr.name];
			}
			// Otherwise use default value if provided
			else if (attr.default_value !== undefined) {
				newAttributes[attr.name] = attr.default_value;
			}
		});
	}

	return newAttributes;
}
