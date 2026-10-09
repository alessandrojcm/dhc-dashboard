<script lang="ts">
import { Button } from "#lib/components/ui/button/index.js";
import { cn } from "#lib/utils.js";

let {
	id,
	label,
	value = $bindable(""),
	tokens,
	multiline = false,
	maxLength,
	invalid = false,
}: {
	id: string;
	label: string;
	value?: string;
	tokens: readonly { value: string; label: string }[];
	multiline?: boolean;
	maxLength?: number;
	invalid?: boolean;
} = $props();

let editor = $state<HTMLDivElement | undefined>();
let error = $state<string | null>(null);
let bookmark = { start: 0, end: 0 };
const history: string[] = [];
const future: string[] = [];

// Keep template syntax at the value boundary, never editable inside a tag.
function parts(source: string) {
	return source
		.split(/(\{\{[A-Za-z]+\}\})/g)
		.filter(Boolean)
		.map((text) => ({
			text,
			token: tokens.find((token) => token.value === text),
		}));
}

function read(node: Node): string {
	if (node instanceof HTMLElement && node.dataset.placeholder)
		return node.dataset.placeholder;
	// Browsers insert NBSPs for trailing/repeated contenteditable spaces.
	if (node.nodeType === Node.TEXT_NODE)
		return (node.textContent ?? "").replace(/\u00a0/g, " ");
	if (node instanceof HTMLBRElement) return "\n";
	return Array.from(node.childNodes).map(read).join("");
}

function selection() {
	const selected = window.getSelection();
	if (!editor || !selected?.rangeCount) return bookmark;
	const range = selected.getRangeAt(0);
	if (
		!editor.contains(range.startContainer) ||
		!editor.contains(range.endContainer)
	)
		return bookmark;
	const before = range.cloneRange();
	before.selectNodeContents(editor);
	before.setEnd(range.startContainer, range.startOffset);
	const through = range.cloneRange();
	through.selectNodeContents(editor);
	through.setEnd(range.endContainer, range.endOffset);
	return {
		start: read(before.cloneContents()).length,
		end: read(through.cloneContents()).length,
	};
}

function rememberSelection() {
	bookmark = selection();
}

function placeCaret(offset: number) {
	if (!editor) return;
	const range = document.createRange();
	let remaining = offset;
	for (const node of editor.childNodes) {
		const length = read(node).length;
		if (remaining <= length) {
			if (node.nodeType === Node.TEXT_NODE) range.setStart(node, remaining);
			else if (remaining === 0) range.setStartBefore(node);
			else range.setStartAfter(node);
			range.collapse(true);
			window.getSelection()?.removeAllRanges();
			window.getSelection()?.addRange(range);
			bookmark = { start: offset, end: offset };
			return;
		}
		remaining -= length;
	}
	range.selectNodeContents(editor);
	range.collapse(false);
	window.getSelection()?.removeAllRanges();
	window.getSelection()?.addRange(range);
	bookmark = { start: offset, end: offset };
}

function renderValue(source: string) {
	if (!editor) return;
	// This empty contenteditable leaf owns its DOM exclusively: Svelte never
	// renders children here, and template text is assigned without innerHTML.
	const nodes = parts(source).map(({ text, token }) => {
		if (!token) return document.createTextNode(text);
		const tag = document.createElement("span");
		tag.contentEditable = "false";
		tag.dataset.placeholder = token.value;
		tag.className = "template-input-tag";
		tag.textContent = token.label;
		tag.setAttribute("aria-label", `${token.label} placeholder`);
		return tag;
	});
	editor.replaceChildren(...nodes);
}

$effect(() => {
	if (editor && read(editor) !== value) {
		// A preset/external value replacement starts a fresh editing history.
		history.length = 0;
		future.length = 0;
		bookmark = { start: value.length, end: value.length };
		renderValue(value);
	}
});

function commit(next: string, caret: number) {
	if (maxLength !== undefined && next.length > maxLength) {
		error = `Make room in the ${label.toLowerCase()} (${maxLength} characters maximum).`;
		renderValue(value);
		editor?.focus();
		placeCaret(Math.min(bookmark.start, value.length));
		return;
	}
	error = null;
	if (next !== value) {
		history.push(value);
		future.length = 0;
	}
	value = next;
	renderValue(next);
	editor?.focus();
	placeCaret(caret);
}

function replaceSelection(text: string) {
	const { start, end } = selection();
	commit(value.slice(0, start) + text + value.slice(end), start + text.length);
}

function deleteTag(event: InputEvent) {
	const backward = event.inputType === "deleteContentBackward";
	if (!backward && event.inputType !== "deleteContentForward") return;
	const { start, end } = selection();
	if (start !== end) return;
	let offset = 0;
	for (const part of parts(value)) {
		const next = offset + part.text.length;
		if (part.token && (backward ? next === start : offset === start)) {
			event.preventDefault();
			commit(value.slice(0, offset) + value.slice(next), offset);
			return;
		}
		offset = next;
	}
}

function onInput(event: Event) {
	if (!editor || (event instanceof InputEvent && event.isComposing)) return;
	const caret = selection().end;
	commit(read(editor), caret);
}

function undo(redo: boolean) {
	const source = redo ? future : history;
	const target = redo ? history : future;
	const next = source.pop();
	if (next === undefined) return;
	target.push(value);
	value = next;
	error = null;
	renderValue(next);
	placeCaret(next.length);
}
</script>

<div class="space-y-1.5">
	<div
		bind:this={editor}
		{id}
		role="textbox"
		aria-label={label}
		aria-multiline={multiline}
		aria-invalid={invalid || error !== null}
		aria-describedby={error ? `${id}-placeholder-error` : undefined}
		contenteditable="true"
		tabindex="0"
		class={cn(
			"border-input bg-background focus-visible:border-ring focus-visible:ring-ring/50 min-h-9 w-full min-w-0 rounded-md border px-3 py-1 text-base whitespace-pre-wrap outline-none focus-visible:ring-[3px] md:text-sm",
			"aria-invalid:border-destructive aria-invalid:ring-destructive/20",
			multiline && "min-h-32 py-2",
		)}
		onblur={rememberSelection}
		onkeyup={rememberSelection}
		onpointerup={rememberSelection}
		oninput={onInput}
		oncompositionend={() => {
			if (editor) commit(read(editor), selection().end);
		}}
		onbeforeinput={(event) => {
			if (
				event.inputType === "insertParagraph" ||
				event.inputType === "insertLineBreak"
			) {
				event.preventDefault();
				if (multiline) replaceSelection("\n");
			} else if (
				event.inputType === "historyUndo" ||
				event.inputType === "historyRedo"
			) {
				event.preventDefault();
				undo(event.inputType === "historyRedo");
			} else deleteTag(event);
		}}
		onkeydown={(event) => {
			if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z") {
				event.preventDefault();
				undo(event.shiftKey);
			}
		}}
		onpaste={(event) => {
			event.preventDefault();
			const text = event.clipboardData?.getData("text/plain") ?? "";
			replaceSelection(multiline ? text : text.replace(/[\r\n]+/g, " "));
		}}
		oncopy={(event) => {
			const { start, end } = selection();
			event.preventDefault();
			event.clipboardData?.setData("text/plain", value.slice(start, end));
		}}
		oncut={(event) => {
			const { start, end } = selection();
			event.preventDefault();
			event.clipboardData?.setData("text/plain", value.slice(start, end));
			commit(value.slice(0, start) + value.slice(end), start);
		}}
		ondrop={(event) => event.preventDefault()}
	></div>
	<div
		class="flex flex-wrap items-center gap-1.5"
		role="group"
		aria-label={`${label} placeholders`}
	>
		<span class="text-xs text-muted-foreground">Insert:</span>
		{#each tokens as token (token.value)}
			<Button
				type="button"
				variant="outline"
				size="sm"
				class="h-6 rounded-full px-2 text-xs font-medium"
				aria-label={`Insert ${token.label.toLowerCase()} into ${label.toLowerCase()}`}
				onclick={() => replaceSelection(token.value)}
			>
				{token.label}
			</Button>
		{/each}
	</div>
	{#if error}
		<p
			id={`${id}-placeholder-error`}
			role="alert"
			class="text-xs font-semibold text-destructive"
		>
			{error}
		</p>
	{/if}
</div>

<style>
:global(.template-input-tag) {
	display: inline-block;
	border-radius: 0.25rem;
	background: hsl(var(--primary) / 0.1);
	padding: 0 0.3rem;
	color: hsl(var(--primary));
	font-size: 0.75rem;
	font-weight: 600;
	line-height: 1.5rem;
	vertical-align: baseline;
	user-select: all;
}
</style>
