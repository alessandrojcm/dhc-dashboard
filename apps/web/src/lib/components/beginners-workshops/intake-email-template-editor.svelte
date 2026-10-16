<!--
	One Intake Email template's editor (ALE-383): the subject with inline
	placeholder chips, the rich-text body with atomic placeholder chips, the
	"N / 2,000" counter and, for action emails, the app-added button as a
	fixed footer. There is no preview, by decision.

	It owns only the draft. Saving is the parent's job (`onsave`), and Phoenix
	is authoritative: the counter and placeholder checks only keep Save
	disabled for drafts Phoenix's save check would refuse, and anything it
	still refuses arrives through `problem`.
-->
<script lang="ts">
import type {
	IntakeEmailDocument,
	IntakeEmailTemplate,
	IntakeEmailTemplateUpdate,
} from "@dhc/api-client";
import { MousePointerClick } from "@lucide/svelte";
import type { ApiProblem } from "#lib/api-error.js";
import { formatDublinTimestamp } from "#lib/club-calendar.js";
import {
	INTAKE_EMAIL_LIMIT,
	measureIntakeEmail,
	refusedSubjectTokens,
} from "#lib/beginners-workshops/intake-emails/measure.js";
import {
	INTAKE_EMAIL_PLACEHOLDER_LABELS,
	INTAKE_EMAIL_RECIPIENT_NOTE,
	INTAKE_EMAIL_TYPES,
} from "#lib/beginners-workshops/intake-emails/presentation.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import {
	type RichTextDocument,
	RichTextEditor,
} from "#lib/components/ui/rich-text-editor/index.js";
import TemplateInput from "#lib/components/ui/template-input.svelte";
import { cn } from "#lib/utils.js";

type Props = {
	template: IntakeEmailTemplate;
	onsave: (draft: IntakeEmailTemplateUpdate) => void;
	saving?: boolean;
	/** Phoenix's refusal of the last save, if any. */
	problem?: ApiProblem | null;
};

const { template, onsave, saving = false, problem = null }: Props = $props();

const SUBJECT_MAX = 200;
const LIMIT_TEXT = INTAKE_EMAIL_LIMIT.toLocaleString("en-IE");

// The parent remounts this editor per template revision ({#key}), so the
// draft starts from the template once and is never re-synced from it.
// svelte-ignore state_referenced_locally
let subject = $state(template.subject);
// svelte-ignore state_referenced_locally
let body = $state<RichTextDocument>(structuredClone(template.body));
let editorKey = $state(0);

const copy = $derived(INTAKE_EMAIL_TYPES[template.emailType]);
const chips = $derived(
	template.placeholders.map((name) => ({
		name,
		label: INTAKE_EMAIL_PLACEHOLDER_LABELS[name],
	})),
);
const subjectTokens = $derived(
	chips.map((chip) => ({ value: `{{${chip.name}}}`, label: chip.label })),
);

const measure = $derived(measureIntakeEmail(body, template.placeholders));
const subjectRefused = $derived(
	refusedSubjectTokens(subject, template.placeholders),
);
const refused = $derived([...new Set([...subjectRefused, ...measure.refused])]);
const subjectProblem = $derived.by(() => {
	const trimmed = subject.trim();
	if (trimmed === "") return "Write a subject.";
	if (/[\r\n]/.test(subject)) return "Keep the subject to one line.";
	if (subject.length > SUBJECT_MAX)
		return `Keep the subject to ${SUBJECT_MAX} characters.`;
	return null;
});
const canSave = $derived(
	!saving &&
		measure.fits &&
		measure.hasText &&
		refused.length === 0 &&
		subjectProblem === null,
);
const serverFields = $derived(
	Object.fromEntries(
		(problem?.fields ?? []).map(({ field, messages }) => [field, messages]),
	),
);

function discard() {
	subject = template.subject;
	body = structuredClone(template.body);
	editorKey += 1;
}

function save(event: SubmitEvent) {
	event.preventDefault();
	if (!canSave) return;
	onsave({
		subject,
		// SAFETY: the editor only produces `doc` documents (see RichTextEditor).
		body: $state.snapshot(body) as IntakeEmailDocument,
	});
}
</script>

<form
	class="flex h-full min-h-0 min-w-0 flex-col overflow-hidden rounded-2xl border border-border bg-card"
	aria-label={`${template.label} template`}
	onsubmit={save}
>
	<header
		class="flex shrink-0 flex-col gap-2 border-b border-border bg-muted/20 p-4 sm:p-5"
	>
		<div class="flex flex-wrap items-center gap-2">
			<h3 class="font-heading text-xl text-foreground">{template.label}</h3>
			<Badge variant="outline">
				{template.kind === "action" ? "With a button" : "Notice"}
			</Badge>
			<span class="text-xs text-muted-foreground">
				Last saved {formatDublinTimestamp(template.updatedAt)}
			</span>
		</div>
	</header>

	<div
		class="min-h-0 flex-1 overflow-y-auto p-4 sm:p-5"
		role="region"
		aria-label="Template fields"
	>
		<div class="flex min-h-full w-full flex-col gap-5 [&>*]:shrink-0">
			<div class="rounded-xl border border-border bg-muted/20 p-4">
				<dl class="grid gap-x-3 gap-y-0.5 text-sm sm:grid-cols-[auto_1fr]">
					<dt class="font-medium">Sent when</dt>
					<dd class="text-muted-foreground">{copy.sentWhen}</dd>
					<dt class="font-medium">Sent to</dt>
					<dd class="text-muted-foreground">
						{copy.recipients}
						{INTAKE_EMAIL_RECIPIENT_NOTE}
					</dd>
				</dl>
				<p class="mt-3 max-w-3xl text-sm leading-5 text-muted-foreground">
					Edits apply to emails queued after you save. Emails already queued
					keep the copy they were queued with.
				</p>
			</div>
			<Field.Field>
				<Field.Label for="intake-email-subject">Subject</Field.Label>
				<TemplateInput
					id="intake-email-subject"
					label="Subject"
					bind:value={subject}
					tokens={subjectTokens}
					maxLength={SUBJECT_MAX}
					invalid={subjectProblem !== null ||
						subjectRefused.length > 0 ||
						serverFields.subject !== undefined}
				/>
				{#if subjectProblem}
					<Field.Error>{subjectProblem}</Field.Error>
				{/if}
				{#each serverFields.subject ?? [] as message (message)}
					<Field.Error>Subject {message}</Field.Error>
				{/each}
			</Field.Field>

			<Field.Field class="flex-1">
				<div class="flex flex-wrap items-center justify-between gap-2">
					<Field.Label for="intake-email-body">Message</Field.Label>
					<span
						class={cn(
							"text-xs font-semibold tabular-nums",
							measure.fits ? "text-muted-foreground" : "text-destructive",
						)}
						data-testid="intake-email-counter"
						aria-live="polite"
					>
						{measure.length.toLocaleString("en-IE")} / {LIMIT_TEXT}
					</span>
				</div>
				{#key editorKey}
					<RichTextEditor
						class="flex min-h-72 flex-1 flex-col [&>div]:shrink-0 [&>div:last-child]:flex [&>div:last-child]:flex-1 [&>div:last-child]:flex-col [&_.tiptap]:flex-1"
						bind:value={body}
						id="intake-email-body"
						aria-label="Message"
						aria-invalid={!measure.fits ||
							measure.refused.length > 0 ||
							serverFields.body !== undefined}
						placeholders={chips}
					/>
				{/key}
				<Field.Description>
					The counter measures the email as sent, with every placeholder at its
					longest (a 40-character first name, an 80-character venue). Formatting
					counts too. Resend allows {LIMIT_TEXT} characters.
				</Field.Description>
				{#if !measure.fits}
					<Field.Error>
						The message is over {LIMIT_TEXT} characters. Shorten it to save.
					</Field.Error>
				{/if}
				{#if !measure.hasText}
					<Field.Error>Write a message.</Field.Error>
				{/if}
				{#each serverFields.body ?? [] as message (message)}
					<Field.Error>Message {message}</Field.Error>
				{/each}
			</Field.Field>

			{#if template.buttonLabel}
				<div
					class="flex flex-wrap items-center gap-3 rounded-xl border border-border bg-muted/20 p-4 text-sm text-foreground"
					role="note"
					aria-label="Button added by the app"
				>
					<MousePointerClick class="size-4 text-primary" aria-hidden="true" />
					<span>Added by the app below the message:</span>
					<span
						class="rounded-lg bg-primary px-3 py-1.5 font-semibold text-primary-foreground"
						>{template.buttonLabel}</span
					>
					<span class="text-xs"
						>It opens the person's page to manage their workshop place.</span
					>
				</div>
			{/if}

			{#if refused.length > 0}
				<Alert.Root variant="destructive">
					<Alert.Title>Not available in this email</Alert.Title>
					<Alert.Description>
						{refused.map((name) => `{{${name}}}`).join(", ")} can't be filled for
						this email. Remove it to save.
					</Alert.Description>
				</Alert.Root>
			{/if}

			{#if problem?.detail}
				<Alert.Root variant="destructive">
					<Alert.Title>Not saved</Alert.Title>
					<Alert.Description>{problem.detail}</Alert.Description>
				</Alert.Root>
			{/if}
		</div>
	</div>
	<div
		class="flex shrink-0 flex-wrap justify-end gap-2 border-t border-border bg-muted/20 p-4 sm:px-5"
	>
		<Button type="button" variant="outline" onclick={discard} disabled={saving}>
			Discard changes
		</Button>
		<Button type="submit" disabled={!canSave}>
			{saving ? "Saving…" : "Save template"}
		</Button>
	</div>
</form>
