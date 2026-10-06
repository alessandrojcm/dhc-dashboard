<!--
	The occurrence inspector (ALE-333): what one calendar item resolved to
	and why, built from the item's `window` payload — never refetched, never
	recomputed.

	- Posts that will not be sent show only their reason, not the backend's
	  precedence checklist.
	- *What members see* is Phoenix's rendered message and thread name,
	  including the `@everyone` line, through the shared Discord preview.
	- Past items show their delivery evidence: display status and reason,
	  checkpoint timestamps, Discord permalink, error detail, thread
	  attempts, and which Suppression or Override applied. In-flight items
	  read "posting…" with the checkpoints that have happened so far.
	- Holiday notices open the same inspector read-only: no per-date
	  actions. A future occurrence offers "skip this date" (a single-date
	  Suppression) and "change copy for this date" (the override form
	  pre-filled for that date); saving either refreshes the calendar's
	  `window` read so the chip updates.
-->
<script lang="ts">
import type {
	TrainingAnnouncement,
	TrainingAnnouncementOccurrence,
} from "@dhc/api-client";
import { useQueryClient } from "@tanstack/svelte-query";
import { Alert, AlertDescription } from "#lib/components/ui/alert/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Sheet from "#lib/components/ui/sheet/index.js";
import { announcementDateLabel } from "#lib/training-announcements/announcement.js";
import { KIND_CHANNEL_LABELS } from "#lib/training-announcements/copy.js";
import {
	evidenceCheckpoints,
	occurrenceNotSentReason,
	inspectorActionsAllowed,
	isInFlightDelivery,
} from "#lib/training-announcements/inspector.js";
import {
	deliveryReasonLabel,
	occurrenceStatus,
	occurrenceTitle,
} from "#lib/training-announcements/status.js";
import DiscordMessagePreview from "./DiscordMessagePreview.svelte";
import OverrideSheet from "./OverrideSheet.svelte";
import SuppressionSheet from "./SuppressionSheet.svelte";

const queryClient = useQueryClient();

let {
	item,
	today,
	announcement,
	onClose,
}: {
	/** The `window` item as the calendar received it — never refetched. */
	item: TrainingAnnouncementOccurrence;
	/** Europe/Dublin today as `YYYY-MM-DD`, from the page load. */
	today: string;
	/** The item's announcement, or `null` for holiday notices. */
	announcement: TrainingAnnouncement | null;
	onClose: () => void;
} = $props();

const status = $derived(occurrenceStatus(item));
const title = $derived(occurrenceTitle(item));
const notSentReason = $derived(occurrenceNotSentReason(item));
const actionsAllowed = $derived(inspectorActionsAllowed(item, today));
const inFlight = $derived(isInFlightDelivery(item.delivery));
const checkpoints = $derived(
	item.delivery ? evidenceCheckpoints(item.delivery) : [],
);
const channelLabel = $derived(
	item.kind ? KIND_CHANNEL_LABELS[item.kind] : "Announcement channel",
);
const appliedSuppressionId = $derived(
	item.delivery?.appliedSuppressionId ?? item.appliedSuppressionId,
);
const appliedOverrideId = $derived(
	item.delivery?.appliedOverrideId ?? item.appliedOverrideId,
);
const isPastWithoutEvidence = $derived(
	item.delivery === null && item.date < today,
);
const actionsBlocked = $derived(announcement === null || announcement.retired);

let action = $state<"suppression" | "override" | null>(null);

/**
 * Slice ids of the occurrence reads a new exception re-resolves — the
 * calendar `window` and the per-announcement lists behind the rail cards
 * and detail column — mirroring the generated `*QueryKey()` helpers, whose
 * full keys also carry the calendar's current `from`/`to` range the
 * inspector never sees. Partial-key matching scopes the refresh to these
 * slices instead of every query on the page.
 */
const OCCURRENCE_READ_IDS = [
	"trainingAnnouncementOccurrencesWindow",
	"trainingAnnouncementOccurrencesListForAnnouncement",
] as const;

function refreshOccurrenceReads() {
	for (const _id of OCCURRENCE_READ_IDS) {
		void queryClient.invalidateQueries({ queryKey: [{ _id }] });
	}
}
</script>

<Sheet.Root
	open
	onOpenChange={(open) => {
		if (!open) onClose();
	}}
>
	<Sheet.Content
		side="right"
		class="w-full overflow-y-auto sm:max-w-lg"
		data-testid="occurrence-inspector"
	>
		<Sheet.Header>
			<Sheet.Title>{title}</Sheet.Title>
			<Sheet.Description>
				{announcementDateLabel(item.date)} · {status.label}{#if item.postTime}
					· {item.postTime.slice(0, 5)}{/if}
			</Sheet.Description>
		</Sheet.Header>

		<div class="space-y-6 px-4 pb-2">
			{#if notSentReason}
				<Alert data-testid="not-sent-reason">
					<AlertDescription>{notSentReason}</AlertDescription>
				</Alert>
			{:else}
				<section aria-label="What members see" data-testid="inspector-message">
					<h3 class="text-sm font-bold">What members see</h3>
					<div class="mt-2">
						{#if item.renderedMessage}
							<DiscordMessagePreview
								{channelLabel}
								renderedMessage={item.renderedMessage}
								threadName={item.threadName}
							/>
						{:else}
							<Alert variant="destructive">
								<AlertDescription>
									The message could not be rendered{#if item.renderErrors.length > 0}:
										{item.renderErrors.join("; ")}{/if}.
								</AlertDescription>
							</Alert>
						{/if}
					</div>
				</section>
			{/if}

			{#if item.delivery}
				<section aria-label="Delivery details" data-testid="delivery-evidence">
					<h3 class="text-sm font-bold">Delivery details</h3>
					{#if inFlight}
						<p
							class="mt-2 text-sm text-muted-foreground"
							data-testid="delivery-inflight"
						>
							Posting to Discord. Delivery details will update when it finishes.
						</p>
					{/if}
					<dl class="mt-2 space-y-1.5 text-sm">
						<div class="flex gap-2">
							<dt class="flex-none font-semibold">Status</dt>
							<dd>{status.label}</dd>
						</div>
						{#if item.delivery.reason !== null}
							<div class="flex gap-2">
								<dt class="flex-none font-semibold">Reason</dt>
								<dd>{deliveryReasonLabel(item.delivery.reason)}</dd>
							</div>
						{/if}
						{#if appliedSuppressionId}
							<div class="flex gap-2" data-testid="applied-suppression">
								<dt class="flex-none font-semibold">Skip entry</dt>
								<dd class="min-w-0 break-all font-mono text-xs">
									{appliedSuppressionId}
								</dd>
							</div>
						{/if}
						{#if appliedOverrideId}
							<div class="flex gap-2" data-testid="applied-override">
								<dt class="flex-none font-semibold">Copy-change entry</dt>
								<dd class="min-w-0 break-all font-mono text-xs">
									{appliedOverrideId}
								</dd>
							</div>
						{/if}
						{#each checkpoints as checkpoint (checkpoint.label)}
							<div class="flex gap-2">
								<dt class="flex-none font-semibold">{checkpoint.label}</dt>
								<dd>
									<time datetime={checkpoint.at}>{checkpoint.at}</time>
								</dd>
							</div>
						{/each}
						{#if item.delivery.permalink}
							<div class="flex gap-2">
								<dt class="flex-none font-semibold">Discord</dt>
								<dd>
									<a
										href={item.delivery.permalink}
										target="_blank"
										rel="noreferrer"
										class="font-semibold text-primary hover:underline"
										data-testid="delivery-permalink">Open in Discord</a
									>
								</dd>
							</div>
						{/if}
						{#if item.delivery.errorDetail}
							<div class="flex gap-2">
								<dt class="flex-none font-semibold">Error</dt>
								<dd class="min-w-0 break-words">{item.delivery.errorDetail}</dd>
							</div>
						{/if}
						{#if item.delivery.threadAttempts > 0}
							<div class="flex gap-2">
								<dt class="flex-none font-semibold">Thread attempts</dt>
								<dd>
									{item.delivery
										.threadAttempts}{#if item.delivery.lastThreadError}
										<span class="text-muted-foreground">
											— last error: {item.delivery.lastThreadError}</span
										>{/if}
								</dd>
							</div>
						{/if}
					</dl>
				</section>
			{:else if isPastWithoutEvidence}
				<section aria-label="Delivery details" data-testid="delivery-evidence">
					<h3 class="text-sm font-bold">Delivery details</h3>
					<p class="mt-2 text-sm text-muted-foreground">
						No delivery details are available for this date.
					</p>
				</section>
			{/if}

			{#if item.subject === "holiday"}
				<p class="text-xs text-muted-foreground">
					Sent automatically on Irish bank holidays, the day before and on the
					day, in place of the roll call. It cannot be edited or skipped.
				</p>
			{:else if actionsAllowed}
				{#if actionsBlocked}
					<p class="text-xs text-muted-foreground">
						This announcement is no longer available to edit.
					</p>
				{:else}
					<div class="flex flex-wrap gap-2">
						<Button
							size="sm"
							variant="outline"
							data-testid="inspector-skip-date"
							onclick={() => (action = "suppression")}
						>
							Skip this date
						</Button>
						<Button
							size="sm"
							variant="outline"
							data-testid="inspector-change-copy"
							onclick={() => (action = "override")}
						>
							Change text for this date
						</Button>
					</div>
				{/if}
			{/if}
		</div>

		<Sheet.Footer>
			<Button variant="ghost" onclick={onClose}>Close</Button>
		</Sheet.Footer>
	</Sheet.Content>
</Sheet.Root>

{#if action === "suppression" && announcement}
	<SuppressionSheet
		{announcement}
		{today}
		initialDate={item.date}
		onClose={() => (action = null)}
		onSaved={refreshOccurrenceReads}
	/>
{/if}

{#if action === "override" && announcement}
	<OverrideSheet
		{announcement}
		{today}
		initialDate={item.date}
		initialTitle={item.titleSource ?? announcement.title}
		initialMessage={item.messageSource ?? announcement.message}
		onClose={() => (action = null)}
		onSaved={refreshOccurrenceReads}
	/>
{/if}
