import { mergeAttributes, Node } from "@tiptap/core";

/** One placeholder the editor may insert: its wire name and chip label. */
export type RichTextPlaceholder = { name: string; label: string };

type PlaceholderChipOptions = {
	/** The only placeholders this document may contain. */
	placeholders: readonly RichTextPlaceholder[];
};

declare module "@tiptap/core" {
	interface Commands<ReturnType> {
		placeholderChip: {
			/** Inserts the named placeholder chip at the selection. */
			insertPlaceholder: (name: string) => ReturnType;
		};
	}
}

/**
 * An inline, atomic placeholder chip (ALE-383).
 *
 * It serialises to exactly the node Phoenix's Intake Email renderer fills,
 * `{"type": "placeholder", "attrs": {"name": "firstName"}}` (marks allowed),
 * and, being an atom, is selected, copied and deleted whole: a chip can't be
 * half-deleted into stray text. Only the configured placeholders can be
 * inserted or pasted in; a pasted chip for any other name is dropped.
 */
export const PlaceholderChip = Node.create<PlaceholderChipOptions>({
	name: "placeholder",
	group: "inline",
	inline: true,
	atom: true,
	selectable: true,
	draggable: false,

	addOptions() {
		return { placeholders: [] };
	},

	addAttributes() {
		return {
			name: {
				default: null,
				parseHTML: (element) => element.getAttribute("data-placeholder"),
				renderHTML: (attributes) => ({
					"data-placeholder": attributes.name,
				}),
			},
		};
	},

	parseHTML() {
		return [
			{
				tag: "span[data-placeholder]",
				getAttrs: (element) =>
					this.options.placeholders.some(
						(placeholder) =>
							placeholder.name === element.getAttribute("data-placeholder"),
					)
						? null
						: false,
			},
		];
	},

	renderHTML({ node, HTMLAttributes }) {
		const name = String(node.attrs.name);
		const label =
			this.options.placeholders.find((placeholder) => placeholder.name === name)
				?.label ?? name;
		return [
			"span",
			mergeAttributes(HTMLAttributes, {
				class: "rich-text-placeholder",
				contenteditable: "false",
				"aria-label": `${label} placeholder`,
			}),
			label,
		];
	},

	renderText({ node }) {
		return `{{${String(node.attrs.name)}}}`;
	},

	addCommands() {
		return {
			insertPlaceholder:
				(name) =>
				({ commands }) =>
					this.options.placeholders.some(
						(placeholder) => placeholder.name === name,
					) && commands.insertContent({ type: this.name, attrs: { name } }),
		};
	},
});
