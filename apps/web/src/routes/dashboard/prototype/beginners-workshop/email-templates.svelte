<!-- PROTOTYPE — throwaway (ALE-372). Email template editor: one club-wide template per
     email type. Rich-text body (Member Announcement vocabulary) with placeholder chips and
     a 2,000-character counter measured on the rendered HTML, each placeholder counted at
     its maximum length. No preview, by decision. -->
<script lang="ts">
import { ArrowLeft, MousePointerClick } from "@lucide/svelte";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import {
	type RichTextDocument,
	RichTextEditor,
} from "#lib/components/ui/rich-text-editor/index.js";
import TemplateInput from "#lib/components/ui/template-input.svelte";
import { cn } from "#lib/utils.js";
import { go } from "./bw-nav";
import {
	EMAIL_TYPES,
	type EmailTypeId,
	emailType,
	fmtDayTime,
	PLACEHOLDERS,
	type Placeholder,
	proto,
} from "./bw-prototype-store.svelte";

const LIMIT = 2000;
let selected = $state<EmailTypeId>("contact_pay");
let subject = $state(proto.templates.contact_pay.subject);
let body = $state<RichTextDocument>(proto.templates.contact_pay.body);
let editorKey = $state(0);
const type = $derived(emailType(selected));
const tokens = $derived(
	type.placeholders.map((key) => ({
		value: `{{${key}}}`,
		label: PLACEHOLDERS[key].label,
	})),
);

function pick(id: EmailTypeId) {
	selected = id;
	subject = proto.templates[id].subject;
	body = structuredClone($state.snapshot(proto.templates[id].body));
	editorKey++;
}

const MARK_TAGS = new Map([
	["bold", "strong"],
	["italic", "em"],
	["underline", "u"],
	["strike", "s"],
]);
const isPlaceholder = (key: string): key is Placeholder => key in PLACEHOLDERS;
const escape = (text: string) =>
	text
		.replaceAll("&", "&amp;")
		.replaceAll("<", "&lt;")
		.replaceAll(">", "&gt;")
		.replaceAll('"', "&quot;");

function render(node: RichTextDocument): string {
	const inner = (node.content ?? []).map(render).join("");
	switch (node.type) {
		case "doc":
			return inner;
		case "paragraph":
			return `<p>${inner}</p>`;
		case "heading":
			return `<h${node.attrs?.level ?? 2}>${inner}</h${node.attrs?.level ?? 2}>`;
		case "bulletList":
			return `<ul>${inner}</ul>`;
		case "orderedList":
			return `<ol>${inner}</ol>`;
		case "listItem":
			return `<li>${inner}</li>`;
		case "blockquote":
			return `<blockquote>${inner}</blockquote>`;
		case "horizontalRule":
			return "<hr>";
		case "hardBreak":
			return "<br>";
		case "text": {
			let html = escape(node.text ?? "");
			for (const mark of node.marks ?? []) {
				const tag = MARK_TAGS.get(mark.type);
				if (tag) html = `<${tag}>${html}</${tag}>`;
				if (mark.type === "link")
					html = `<a href="${escape(String(mark.attrs?.href ?? ""))}">${html}</a>`;
			}
			return html;
		}
		default:
			return inner;
	}
}

const html = $derived(render(body));
const worstCase = $derived(
	html.replace(/\{\{([a-zA-Z]+)\}\}/g, (match, key: string) =>
		isPlaceholder(key) ? "x".repeat(PLACEHOLDERS[key].max) : match,
	),
);
const used = $derived(
	[...`${subject} ${html}`.matchAll(/\{\{([a-zA-Z]+)\}\}/g)].map(
		(match) => match[1] ?? "",
	),
);
const invalid = $derived([
	...new Set(
		used.filter(
			(key) => !isPlaceholder(key) || !type.placeholders.includes(key),
		),
	),
]);
const count = $derived(worstCase.length);

function insert(key: Placeholder) {
	const doc: RichTextDocument = $state.snapshot(body);
	const content = doc.content ?? [];
	let last = content.at(-1);
	if (!last || last.type !== "paragraph") {
		last = { type: "paragraph", content: [] };
		content.push(last);
	}
	last.content = [
		...(last.content ?? []),
		{ type: "text", text: `{{${key}}}` },
	];
	doc.content = content;
	body = doc;
	editorKey++;
}
</script>

<div class="flex flex-col gap-5">
	<button
		type="button"
		class="flex w-fit cursor-pointer items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
		onclick={() => go("workshops")}
	>
		<ArrowLeft class="size-4" /> Beginners' Workshops
	</button>
	<header>
		<h1 class="font-heading text-3xl">Intake Email templates</h1>
		<p class="text-sm text-muted-foreground">
			One club-wide template per email. Each workshop's details fill the
			placeholders; the app adds the link button. Edits affect emails queued
			from now on.
		</p>
	</header>

	<div class="grid gap-6 lg:grid-cols-[18rem_1fr]">
		<nav class="flex flex-col gap-4" aria-label="Email types">
			{#each [["action", "With a button (open Intakes)"], ["notice", "Notices (closed Intakes)"]] as const as [kind, title] (kind)}
				<div class="flex flex-col gap-1">
					<h2
						class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
					>
						{title}
					</h2>
					{#each EMAIL_TYPES.filter((candidate) => candidate.kind === kind) as candidate (candidate.id)}
						<button
							type="button"
							class={cn(
								"cursor-pointer rounded-lg px-3 py-2 text-left text-sm",
								selected === candidate.id
									? "bg-primary text-primary-foreground"
									: "hover:bg-muted",
							)}
							onclick={() => pick(candidate.id)}
						>
							<span class="block font-medium">{candidate.label}</span>
							<span
								class={cn(
									"block text-xs",
									selected === candidate.id
										? "text-primary-foreground/80"
										: "text-muted-foreground",
								)}>{candidate.trigger}</span
							>
						</button>
					{/each}
				</div>
			{/each}
		</nav>

		<section class="flex flex-col gap-4 rounded-2xl border bg-card p-5">
			<div class="flex flex-wrap items-center gap-2">
				<h2 class="font-heading text-xl">{type.label}</h2>
				<Badge variant="outline">{type.kind}</Badge>
				{#if proto.templates[selected].updatedAt}<span
						class="text-xs text-muted-foreground"
						>last saved {fmtDayTime(
							proto.templates[selected].updatedAt as string,
						)}</span
					>{/if}
			</div>
			<p class="text-sm text-muted-foreground">
				Sent when: {type.trigger}. To the person only, never a Guardian.
				Reply-To contact@.
			</p>

			<div class="grid gap-2">
				<Label for="tpl-subject">Subject</Label>
				{#key selected}
					<TemplateInput
						id="tpl-subject"
						label="Subject"
						bind:value={subject}
						{tokens}
					/>
				{/key}
			</div>

			<div class="grid gap-2">
				<div class="flex flex-wrap items-center justify-between gap-2">
					<Label>Body</Label>
					<span
						class={cn(
							"text-xs font-semibold tabular-nums",
							count > LIMIT
								? "text-destructive"
								: count > LIMIT * 0.9
									? "text-amber-700"
									: "text-muted-foreground",
						)}
					>
						{count.toLocaleString()} / {LIMIT.toLocaleString()}
					</span>
				</div>
				<div
					class="flex flex-wrap items-center gap-1.5"
					role="group"
					aria-label="Body placeholders"
				>
					<span class="text-xs text-muted-foreground">Insert:</span>
					{#each type.placeholders as key (key)}
						<Button
							type="button"
							variant="outline"
							size="sm"
							class="h-6 rounded-full px-2 text-xs"
							onclick={() => insert(key)}>{PLACEHOLDERS[key].label}</Button
						>
					{/each}
					<span class="text-[11px] text-muted-foreground italic"
						>(prototype appends; the build inserts a chip at the cursor)</span
					>
				</div>
				{#key editorKey}
					<RichTextEditor bind:value={body} aria-label="Body" />
				{/key}
				<p class="text-xs text-muted-foreground">
					The counter measures the HTML Phoenix will send, with each placeholder
					at its longest value (e.g. a 40-character first name). Formatting
					counts too.
				</p>
			</div>

			{#if type.button}
				<div
					class="flex items-center gap-3 rounded-xl border-2 border-dashed p-3 text-sm text-muted-foreground"
				>
					<MousePointerClick class="size-4" />
					Button added by the app:
					<span
						class="rounded-lg bg-primary px-3 py-1.5 font-semibold text-primary-foreground"
						>{type.button}</span
					>
					<span class="text-xs"
						>(label and link depend on the Intake's state)</span
					>
				</div>
			{/if}

			{#if invalid.length}
				<p class="text-sm font-semibold text-destructive">
					Not available in this email: {invalid
						.map((key) => `{{${key}}}`)
						.join(", ")}
				</p>
			{/if}

			<div class="flex justify-end gap-2">
				<Button variant="outline" onclick={() => pick(selected)}
					>Discard changes</Button
				>
				<Button
					disabled={count > LIMIT || invalid.length > 0}
					onclick={() =>
						proto.saveTemplate(selected, subject, $state.snapshot(body), count)}
					>Save template</Button
				>
			</div>
		</section>
	</div>
</div>
