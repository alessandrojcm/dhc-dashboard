<script lang="ts">
/**
 * Member Emails (ADR 0028): compose a rich-text announcement, watch the
 * exact email Phoenix would send render beside it, and send it to every
 * active member (optionally inactive members too). Phoenix renders the
 * preview, so the preview is the email.
 */
import {
	memberAnnouncementsCreateMutation,
	memberAnnouncementsIndexOptions,
	memberAnnouncementsIndexQueryKey,
	memberAnnouncementsPreviewMutation,
	type MemberAnnouncement,
	type MemberAnnouncementDraft,
	type MemberAnnouncementStatus,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	useQueryClient,
} from "@tanstack/svelte-query";
import { LoaderCircle, Mail, Send } from "@lucide/svelte";
import { toast } from "svelte-sonner";
import { apiProblem } from "#lib/api-error.js";
import * as AlertDialog from "#lib/components/ui/alert-dialog/index.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Checkbox } from "#lib/components/ui/checkbox/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import {
	emptyRichTextDocument,
	RichTextEditor,
	type RichTextDocument,
} from "#lib/components/ui/rich-text-editor/index.js";
import {
	draftHasText,
	previewKey,
	PREVIEW_SUBJECT_FALLBACK,
} from "#lib/member-announcements/draft.js";

const PREVIEW_DEBOUNCE_MS = 400;
const SUBJECT_MAX = 200;

const queryClient = useQueryClient();

let subject = $state("");
let body = $state<RichTextDocument>(emptyRichTextDocument());
let includeInactive = $state(false);
// Remounts the editor after a send so it starts empty again.
let editorKey = $state(0);
let confirmOpen = $state(false);

let previewHtml = $state<string | null>(null);
let recipientCount = $state<number | null>(null);
let previewError = $state<string | null>(null);
let fieldErrors = $state<Record<string, string[]>>({});

const hasText = $derived(draftHasText(body));
const subjectTrimmed = $derived(subject.trim());
const canSend = $derived(
	hasText &&
		subjectTrimmed !== "" &&
		subjectTrimmed.length <= SUBJECT_MAX &&
		(recipientCount ?? 0) > 0,
);

function draft(forPreview: boolean): MemberAnnouncementDraft {
	return {
		subject:
			forPreview && subjectTrimmed === ""
				? PREVIEW_SUBJECT_FALLBACK
				: subjectTrimmed,
		// SAFETY: the editor only produces `doc` documents (see RichTextEditor).
		body: body as MemberAnnouncementDraft["body"],
		includeInactive,
	};
}

const previewMutation = createMutation(() => ({
	...memberAnnouncementsPreviewMutation(),
	onSuccess: (response) => {
		previewHtml = response.data.html;
		recipientCount = response.data.recipientCount;
		previewError = null;
	},
	onError: (error) => {
		const problem = apiProblem(error);
		previewError = problem?.detail ?? "The preview could not be rendered.";
	},
}));

const sendMutation = createMutation(() => ({
	...memberAnnouncementsCreateMutation(),
	onSuccess: (response) => {
		const count = response.data.recipientCount;
		toast.success(
			`Sending to ${count} member${count === 1 ? "" : "s"}. The status below updates when Resend accepts it.`,
		);
		confirmOpen = false;
		subject = "";
		body = emptyRichTextDocument();
		includeInactive = false;
		previewHtml = null;
		fieldErrors = {};
		editorKey += 1;
		void queryClient.invalidateQueries({
			queryKey: memberAnnouncementsIndexQueryKey(),
		});
	},
	onError: (error) => {
		const problem = apiProblem(error);
		fieldErrors = Object.fromEntries(
			(problem?.fields ?? []).map(({ field, messages }) => [field, messages]),
		);
		confirmOpen = false;
		toast.error(problem?.detail ?? "The email could not be sent.");
	},
}));

// Debounced live preview. The key captures everything the render depends on,
// so typing re-renders and an unchanged draft does not.
let lastPreviewKey = "";
$effect(() => {
	const key = previewKey(draft(true));
	if (!hasText) {
		previewHtml = null;
		previewError = null;
		lastPreviewKey = "";
		return;
	}
	if (key === lastPreviewKey) return;
	const timer = setTimeout(() => {
		lastPreviewKey = key;
		previewMutation.mutate({ body: draft(true) });
	}, PREVIEW_DEBOUNCE_MS);
	return () => clearTimeout(timer);
});

const historyQuery = createQuery(() => ({
	...memberAnnouncementsIndexOptions(),
	// Poll only while something is still queued.
	refetchInterval: (query) =>
		query.state.data?.data.some((row) => row.status === "queued")
			? 5_000
			: false,
}));

const statusLabels = {
	queued: "Sending",
	sent: "Sent",
	failed: "Failed",
} satisfies Record<MemberAnnouncementStatus, string>;

const statusVariants = {
	queued: "secondary",
	sent: "default",
	failed: "destructive",
} as const satisfies Record<MemberAnnouncementStatus, string>;

const dateFormat = new Intl.DateTimeFormat("en-IE", {
	dateStyle: "medium",
	timeStyle: "short",
	timeZone: "Europe/Dublin",
});

function audienceLabel(row: MemberAnnouncement) {
	return row.includeInactive ? "Active + inactive" : "Active members";
}
</script>

<svelte:head>
	<title>Member Emails | Dublin HEMA Club</title>
</svelte:head>

<div
	class="mx-auto w-full max-w-7xl space-y-6 px-4 py-6 sm:px-6 sm:py-8 lg:px-8"
>
	<header class="border-b border-border/80 pb-5">
		<div class="flex items-start gap-4">
			<div
				class="hidden size-12 shrink-0 place-items-center rounded-2xl border border-primary/15 bg-primary/10 text-primary sm:grid"
				aria-hidden="true"
			>
				<Mail class="size-6" />
			</div>
			<div class="min-w-0">
				<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
					Committee
				</p>
				<h1 class="font-heading text-3xl leading-tight font-bold sm:text-4xl">
					Member Emails
				</h1>
				<p
					class="mt-2 max-w-2xl text-sm leading-relaxed text-muted-foreground sm:text-base"
				>
					Email the whole membership at once. Every recipient is BCC'd, so
					nobody sees anyone else's address.
				</p>
			</div>
		</div>
	</header>

	<div class="grid gap-6 lg:grid-cols-2">
		<section class="space-y-5" aria-labelledby="compose-heading">
			<h2 id="compose-heading" class="sr-only">Compose</h2>
			<Field.Field>
				<Field.Label for="member-email-subject">Subject</Field.Label>
				<Input
					id="member-email-subject"
					bind:value={subject}
					maxlength={SUBJECT_MAX}
					placeholder="e.g. Annual General Meeting"
					aria-invalid={Boolean(fieldErrors.subject)}
				/>
				<Field.Description>Also shown as the email heading.</Field.Description>
				{#each fieldErrors.subject ?? [] as message (message)}
					<Field.Error>{message}</Field.Error>
				{/each}
			</Field.Field>

			<Field.Field>
				<Field.Label for="member-email-body">Message</Field.Label>
				{#key editorKey}
					<RichTextEditor
						id="member-email-body"
						aria-label="Message"
						placeholder="Write your announcement…"
						bind:value={body}
						aria-invalid={Boolean(fieldErrors.body)}
						disabled={sendMutation.isPending}
					/>
				{/key}
				{#each fieldErrors.body ?? [] as message (message)}
					<Field.Error>{message}</Field.Error>
				{/each}
			</Field.Field>

			<Field.Field orientation="horizontal">
				<Checkbox
					id="member-email-include-inactive"
					bind:checked={includeInactive}
				/>
				<Field.Content>
					<Field.Label for="member-email-include-inactive">
						Also email inactive members
					</Field.Label>
					<Field.Description>
						Active members (including paused memberships) always receive it.
					</Field.Description>
				</Field.Content>
			</Field.Field>

			<div class="flex flex-wrap items-center justify-between gap-3">
				<p class="text-sm text-muted-foreground" aria-live="polite">
					{#if recipientCount !== null && hasText}
						{recipientCount} recipient{recipientCount === 1 ? "" : "s"}
					{/if}
				</p>
				<Button
					disabled={!canSend || sendMutation.isPending}
					onclick={() => (confirmOpen = true)}
				>
					<Send />
					Send email
				</Button>
			</div>
		</section>

		<section class="space-y-2" aria-labelledby="preview-heading">
			<div class="flex items-center justify-between">
				<h2 id="preview-heading" class="text-sm font-semibold">Preview</h2>
				{#if previewMutation.isPending}
					<LoaderCircle
						class="size-4 animate-spin text-muted-foreground"
						aria-label="Rendering preview"
					/>
				{/if}
			</div>
			<div class="overflow-hidden rounded-md border border-border bg-white">
				{#if previewHtml}
					<!-- The HTML is Phoenix's render; the sandbox keeps it inert. -->
					<iframe
						title="Email preview"
						class="h-[640px] w-full"
						sandbox=""
						srcdoc={previewHtml}
					></iframe>
				{:else}
					<p
						class="grid h-[640px] place-items-center px-6 text-center text-sm text-muted-foreground"
					>
						Start writing to see the email exactly as members will receive it.
					</p>
				{/if}
			</div>
			{#if previewError}
				<p class="text-sm text-destructive" role="alert">{previewError}</p>
			{/if}
		</section>
	</div>

	<section class="space-y-3" aria-labelledby="history-heading">
		<h2 id="history-heading" class="font-heading text-xl font-bold">
			Recently sent
		</h2>
		{#if historyQuery.isPending}
			<p class="text-sm text-muted-foreground">Loading…</p>
		{:else if historyQuery.isError}
			<p class="text-sm text-destructive">Could not load recent emails.</p>
		{:else if historyQuery.data.data.length === 0}
			<p class="text-sm text-muted-foreground">No member emails sent yet.</p>
		{:else}
			<ul class="divide-y divide-border rounded-md border border-border">
				{#each historyQuery.data.data as row (row.id)}
					<li
						class="flex flex-wrap items-center justify-between gap-2 px-4 py-3"
					>
						<div class="min-w-0">
							<p class="truncate font-medium">{row.subject}</p>
							<p class="text-xs text-muted-foreground">
								{dateFormat.format(new Date(row.createdAt))}
								· {row.recipientCount} recipients · {audienceLabel(row)}
								{#if row.sentByName}· {row.sentByName}{/if}
							</p>
							{#if row.failureReason}
								<p class="text-xs text-destructive">{row.failureReason}</p>
							{/if}
						</div>
						<Badge variant={statusVariants[row.status]}>
							{statusLabels[row.status]}
						</Badge>
					</li>
				{/each}
			</ul>
		{/if}
	</section>
</div>

<AlertDialog.Root bind:open={confirmOpen}>
	<AlertDialog.Content>
		<AlertDialog.Header>
			<AlertDialog.Title>Send this email?</AlertDialog.Title>
			<AlertDialog.Description>
				“{subjectTrimmed}” goes to {recipientCount ?? 0}
				{includeInactive ? "active and inactive" : "active"} member{recipientCount ===
				1
					? ""
					: "s"}. This cannot be undone.
			</AlertDialog.Description>
		</AlertDialog.Header>
		<AlertDialog.Footer>
			<AlertDialog.Cancel disabled={sendMutation.isPending}>
				Cancel
			</AlertDialog.Cancel>
			<Button
				disabled={sendMutation.isPending}
				onclick={() => sendMutation.mutate({ body: draft(false) })}
			>
				{#if sendMutation.isPending}
					<LoaderCircle class="animate-spin" />
				{/if}
				Send
			</Button>
		</AlertDialog.Footer>
	</AlertDialog.Content>
</AlertDialog.Root>
