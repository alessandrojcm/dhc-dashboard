<script lang="ts" module>
import type { JSONContent } from "@tiptap/core";

export type RichTextDocument = JSONContent;

/** An empty document, the editor's initial value. */
export function emptyRichTextDocument(): RichTextDocument {
	return { type: "doc", content: [{ type: "paragraph" }] };
}
</script>

<script lang="ts">
/**
 * Rich-text editor primitive (Tiptap v3 on @tiptap/core, no React).
 *
 * The vocabulary is deliberately small and matches what Phoenix accepts for
 * a Member Announcement body (`Dhc.MemberAnnouncements.Document`, ADR 0028):
 * paragraphs, headings 2–3, bullet/ordered lists, blockquote, horizontal
 * rule, hard break, and bold/italic/underline/strike/link (http, https,
 * mailto). Code, code blocks and heading 1 are disabled so the editor cannot
 * produce a document Phoenix would reject.
 *
 * `value` is the Tiptap JSON document (`editor.getJSON()`); it is written on
 * every content change. The editor is created on mount only, so it never runs
 * during SSR.
 */
import { Editor } from "@tiptap/core";
import { Placeholder } from "@tiptap/extensions";
import { StarterKit } from "@tiptap/starter-kit";
import {
	Bold,
	Heading2,
	Heading3,
	Italic,
	Link as LinkIcon,
	List,
	ListOrdered,
	Minus,
	Quote,
	Redo,
	Strikethrough,
	Underline,
	Undo,
	Unlink,
} from "@lucide/svelte";
import { onDestroy, onMount } from "svelte";
import * as v from "valibot";
import { Button } from "#lib/components/ui/button/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import * as Popover from "#lib/components/ui/popover/index.js";
import { Toggle } from "#lib/components/ui/toggle/index.js";
import { cn } from "#lib/utils.js";

type Props = {
	value?: RichTextDocument;
	placeholder?: string;
	id?: string;
	"aria-label"?: string;
	"aria-invalid"?: boolean;
	disabled?: boolean;
	class?: string;
};

let {
	value = $bindable(emptyRichTextDocument()),
	placeholder = "",
	id,
	"aria-label": ariaLabel,
	"aria-invalid": ariaInvalid = false,
	disabled = false,
	class: className,
}: Props = $props();

const LINK_PATTERN = /^(https?:\/\/[^\s]+|mailto:[^\s]+)$/i;

let element = $state<HTMLDivElement>();
// Reassigned on every transaction so toolbar state re-renders (Tiptap's
// documented Svelte pattern).
let editorState = $state<{ editor: Editor | null }>({ editor: null });
let linkOpen = $state(false);
let linkDraft = $state("");
const linkValid = $derived(LINK_PATTERN.test(linkDraft.trim()));

/** The contenteditable's attributes; `id`/`aria-label` only when given. */
function editorAttributes() {
	const attributes = new Map([
		[
			"class",
			"prose prose-sm max-w-none min-h-56 px-3 py-2 focus:outline-none dark:prose-invert",
		],
		["role", "textbox"],
		["aria-multiline", "true"],
	]);
	if (id) attributes.set("id", id);
	if (ariaLabel) attributes.set("aria-label", ariaLabel);
	return Object.fromEntries(attributes);
}

onMount(() => {
	editorState.editor = new Editor({
		element,
		editable: !disabled,
		content: value,
		extensions: [
			StarterKit.configure({
				heading: { levels: [2, 3] },
				code: false,
				codeBlock: false,
				link: {
					openOnClick: false,
					autolink: true,
					isAllowedUri: (url, ctx) =>
						ctx.defaultValidate(url) && LINK_PATTERN.test(url),
				},
			}),
			Placeholder.configure({ placeholder }),
		],
		editorProps: { attributes: editorAttributes() },
		onTransaction: ({ editor }) => {
			editorState = { editor };
		},
		onUpdate: ({ editor }) => {
			value = editor.getJSON();
		},
	});
});

onDestroy(() => editorState.editor?.destroy());

$effect(() => {
	editorState.editor?.setEditable(!disabled);
});

type Action = {
	label: string;
	icon: typeof Bold;
	active: (editor: Editor) => boolean;
	run: (editor: Editor) => void;
};

const marks: Action[] = [
	{
		label: "Bold",
		icon: Bold,
		active: (e) => e.isActive("bold"),
		run: (e) => e.chain().focus().toggleBold().run(),
	},
	{
		label: "Italic",
		icon: Italic,
		active: (e) => e.isActive("italic"),
		run: (e) => e.chain().focus().toggleItalic().run(),
	},
	{
		label: "Underline",
		icon: Underline,
		active: (e) => e.isActive("underline"),
		run: (e) => e.chain().focus().toggleUnderline().run(),
	},
	{
		label: "Strikethrough",
		icon: Strikethrough,
		active: (e) => e.isActive("strike"),
		run: (e) => e.chain().focus().toggleStrike().run(),
	},
];

const blocks: Action[] = [
	{
		label: "Heading",
		icon: Heading2,
		active: (e) => e.isActive("heading", { level: 2 }),
		run: (e) => e.chain().focus().toggleHeading({ level: 2 }).run(),
	},
	{
		label: "Subheading",
		icon: Heading3,
		active: (e) => e.isActive("heading", { level: 3 }),
		run: (e) => e.chain().focus().toggleHeading({ level: 3 }).run(),
	},
	{
		label: "Bulleted list",
		icon: List,
		active: (e) => e.isActive("bulletList"),
		run: (e) => e.chain().focus().toggleBulletList().run(),
	},
	{
		label: "Numbered list",
		icon: ListOrdered,
		active: (e) => e.isActive("orderedList"),
		run: (e) => e.chain().focus().toggleOrderedList().run(),
	},
	{
		label: "Quote",
		icon: Quote,
		active: (e) => e.isActive("blockquote"),
		run: (e) => e.chain().focus().toggleBlockquote().run(),
	},
];

function openLink(open: boolean) {
	linkOpen = open;
	if (open) {
		const href = v.safeParse(
			v.string(),
			editorState.editor?.getAttributes("link").href,
		);
		linkDraft = href.success ? href.output : "https://";
	}
}

function applyLink(event: SubmitEvent) {
	event.preventDefault();
	const editor = editorState.editor;
	if (!editor || !linkValid) return;
	editor
		.chain()
		.focus()
		.extendMarkRange("link")
		.setLink({ href: linkDraft.trim() })
		.run();
	linkOpen = false;
}
</script>

<div
	class={cn(
		"rounded-md border border-input bg-background shadow-xs focus-within:border-ring focus-within:ring-[3px] focus-within:ring-ring/50",
		ariaInvalid && "border-destructive",
		disabled && "opacity-60",
		className,
	)}
	data-slot="rich-text-editor"
>
	{#if editorState.editor}
		{@const editor = editorState.editor}
		<div
			class="flex flex-wrap items-center gap-0.5 border-b border-input p-1"
			role="toolbar"
			aria-label="Formatting"
		>
			{#each marks as action (action.label)}
				<Toggle
					size="sm"
					aria-label={action.label}
					title={action.label}
					pressed={action.active(editor)}
					onPressedChange={() => action.run(editor)}
					{disabled}
				>
					<action.icon />
				</Toggle>
			{/each}
			<span class="mx-1 h-5 w-px bg-border" aria-hidden="true"></span>
			{#each blocks as action (action.label)}
				<Toggle
					size="sm"
					aria-label={action.label}
					title={action.label}
					pressed={action.active(editor)}
					onPressedChange={() => action.run(editor)}
					{disabled}
				>
					<action.icon />
				</Toggle>
			{/each}
			<Button
				variant="ghost"
				size="icon-sm"
				aria-label="Divider"
				title="Divider"
				onclick={() => editor.chain().focus().setHorizontalRule().run()}
				{disabled}
			>
				<Minus />
			</Button>
			<span class="mx-1 h-5 w-px bg-border" aria-hidden="true"></span>
			<Popover.Root open={linkOpen} onOpenChange={openLink}>
				<Popover.Trigger>
					{#snippet child({ props })}
						<Toggle
							{...props}
							size="sm"
							aria-label="Link"
							title="Link"
							pressed={editor.isActive("link")}
							{disabled}
						>
							<LinkIcon />
						</Toggle>
					{/snippet}
				</Popover.Trigger>
				<Popover.Content class="w-80">
					<form class="flex gap-2" onsubmit={applyLink}>
						<Input
							aria-label="Link address"
							placeholder="https://"
							bind:value={linkDraft}
							aria-invalid={!linkValid}
						/>
						<Button type="submit" size="sm" disabled={!linkValid}>Apply</Button>
					</form>
				</Popover.Content>
			</Popover.Root>
			<Button
				variant="ghost"
				size="icon-sm"
				aria-label="Remove link"
				title="Remove link"
				disabled={disabled || !editor.isActive("link")}
				onclick={() => editor.chain().focus().unsetLink().run()}
			>
				<Unlink />
			</Button>
			<span class="ml-auto"></span>
			<Button
				variant="ghost"
				size="icon-sm"
				aria-label="Undo"
				title="Undo"
				disabled={disabled || !editor.can().undo()}
				onclick={() => editor.chain().focus().undo().run()}
			>
				<Undo />
			</Button>
			<Button
				variant="ghost"
				size="icon-sm"
				aria-label="Redo"
				title="Redo"
				disabled={disabled || !editor.can().redo()}
				onclick={() => editor.chain().focus().redo().run()}
			>
				<Redo />
			</Button>
		</div>
	{/if}
	<div bind:this={element}></div>
</div>

<style>
/* Tiptap's Placeholder extension marks the empty first node. */
:global(
	[data-slot="rich-text-editor"] .tiptap p.is-editor-empty:first-child::before
) {
	content: attr(data-placeholder);
	float: left;
	height: 0;
	pointer-events: none;
	color: var(--color-muted-foreground);
}
</style>
