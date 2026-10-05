<!--
	The selected announcement's detail column (ALE-331): its next post by the
	resolved title Phoenix computed — never the template — and the capped
	lists of its Suppressions and Overrides.

	Reads go through the typed client: the two exception lists and the next
	upcoming occurrence. Writes are the sheets (which own their field errors)
	and the two-step remove buttons here; a removal failure toasts because
	there is no form for it to attach to. Past deliveries keep their evidence:
	removing an exception nulls the reference without rewriting history.
-->
<script lang="ts">
import {
	trainingAnnouncementExceptionsDeleteOverrideMutation,
	trainingAnnouncementExceptionsDeleteSuppressionMutation,
	trainingAnnouncementExceptionsListOverridesOptions,
	trainingAnnouncementExceptionsListOverridesQueryKey,
	trainingAnnouncementExceptionsListSuppressionsOptions,
	trainingAnnouncementExceptionsListSuppressionsQueryKey,
	trainingAnnouncementOccurrencesListForAnnouncementOptions,
	type TrainingAnnouncement,
	type TrainingAnnouncementError,
	type TrainingAnnouncementOverride,
	type TrainingAnnouncementSuppression,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	useQueryClient,
} from "@tanstack/svelte-query";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import { Skeleton } from "$lib/components/ui/skeleton";
import { Ban, Pencil, Plus, Trash2 } from "@lucide/svelte";
import { apiErrorMessage } from "$lib/api-error";
import { toast } from "svelte-sonner";
import { announcementDateLabel } from "$lib/training-announcements/announcement";
import {
	cappedExceptions,
	EXCEPTION_LIST_LIMIT,
	nextResolvedTitle,
	overrideRangeLabel,
	overrideSummary,
	suppressionRangeLabel,
	type CappedExceptionList,
} from "$lib/training-announcements/exceptions";
import OverrideSheet from "./OverrideSheet.svelte";
import SuppressionSheet from "./SuppressionSheet.svelte";

let {
	announcement,
	today,
	onEdit,
}: {
	announcement: TrainingAnnouncement;
	/** Europe/Dublin today as `YYYY-MM-DD`, from the page load. */
	today: string;
	onEdit: (announcement: TrainingAnnouncement) => void;
} = $props();

const queryClient = useQueryClient();

let showAllSuppressions = $state(false);
let showAllOverrides = $state(false);
let suppressionSheetOpen = $state(false);
let overrideSheetOpen = $state(false);
let confirming = $state<{
	kind: "suppression" | "override";
	id: string;
} | null>(null);

const suppressions = createQuery(() => ({
	...trainingAnnouncementExceptionsListSuppressionsOptions({
		path: { id: announcement.id },
	}),
	select: (response) => response.data,
}));

const overrides = createQuery(() => ({
	...trainingAnnouncementExceptionsListOverridesOptions({
		path: { id: announcement.id },
	}),
	select: (response) => response.data,
}));

const upcoming = createQuery(() => ({
	...trainingAnnouncementOccurrencesListForAnnouncementOptions({
		path: { id: announcement.id },
		query: { direction: "upcoming", limit: 1 },
	}),
	select: (response) => response.data,
}));

const resolvedTitle = $derived(nextResolvedTitle(upcoming.data));
const nextDate = $derived(upcoming.data?.[0]?.date);

function refreshExceptions() {
	void queryClient.invalidateQueries({
		queryKey: trainingAnnouncementExceptionsListSuppressionsQueryKey({
			path: { id: announcement.id },
		}),
	});
	void queryClient.invalidateQueries({
		queryKey: trainingAnnouncementExceptionsListOverridesQueryKey({
			path: { id: announcement.id },
		}),
	});
}

function removeOptions(fallback: string) {
	return {
		onSuccess: () => {
			confirming = null;
			refreshExceptions();
			toast.success("Removed.");
		},
		onError: (cause: TrainingAnnouncementError) => {
			toast.error(apiErrorMessage(cause, fallback));
		},
	};
}

const deleteSuppression = createMutation(() => ({
	...trainingAnnouncementExceptionsDeleteSuppressionMutation(),
	...removeOptions("Could not remove this skip"),
}));

const deleteOverride = createMutation(() => ({
	...trainingAnnouncementExceptionsDeleteOverrideMutation(),
	...removeOptions("Could not remove this text change"),
}));

const removing = $derived(
	deleteSuppression.isPending || deleteOverride.isPending,
);

function askRemove(kind: "suppression" | "override", id: string) {
	confirming = { kind, id };
}

function confirmRemove() {
	if (!confirming || removing) return;
	if (confirming.kind === "suppression") {
		deleteSuppression.mutate({
			path: { id: announcement.id, exceptionId: confirming.id },
		});
	} else {
		deleteOverride.mutate({
			path: { id: announcement.id, exceptionId: confirming.id },
		});
	}
}

function suppressionRows(
	rows: TrainingAnnouncementSuppression[] | undefined,
): CappedExceptionList<TrainingAnnouncementSuppression> {
	if (!rows) return { visible: [], hidden: 0 };
	if (showAllSuppressions) return { visible: rows, hidden: 0 };
	return cappedExceptions(rows);
}

function overrideRows(
	rows: TrainingAnnouncementOverride[] | undefined,
): CappedExceptionList<TrainingAnnouncementOverride> {
	if (!rows) return { visible: rows ?? [], hidden: 0 };
	if (showAllOverrides) return { visible: rows, hidden: 0 };
	return cappedExceptions(rows);
}
</script>

<section
	aria-label={`Manage posts for ${announcement.title}`}
	class="rounded-2xl border border-border/80 bg-card p-4 shadow-sm sm:p-5"
	data-testid="announcement-detail"
>
	<div class="flex flex-wrap items-start justify-between gap-3">
		<div class="min-w-0">
			<p
				class="text-[0.6875rem] font-bold tracking-[0.12em] text-muted-foreground uppercase"
			>
				Selected announcement
			</p>
			<h2 class="mt-0.5 truncate font-semibold">{announcement.title}</h2>
			{#if upcoming.isPending}
				<Skeleton class="mt-2 h-4 w-48" />
			{:else if resolvedTitle && nextDate}
				<p class="mt-1 text-sm text-muted-foreground" data-testid="next-post">
					Next post: <span class="font-semibold text-foreground"
						>{resolvedTitle}</span
					>
					on {announcementDateLabel(nextDate)}
				</p>
			{:else}
				<p class="mt-1 text-sm text-muted-foreground">No upcoming posts.</p>
			{/if}
		</div>
		<Button
			size="sm"
			variant="outline"
			disabled={announcement.retired}
			aria-label={`Edit ${announcement.title}`}
			onclick={() => onEdit(announcement)}
		>
			<Pencil class="size-4" aria-hidden="true" />Edit
		</Button>
	</div>

	<div class="mt-5 grid gap-5 md:grid-cols-2">
		<div>
			<div class="flex items-center justify-between gap-2">
				<h3 class="text-sm font-bold">
					Skipped dates
					{#if suppressions.data}
						<span class="font-medium text-muted-foreground"
							>({suppressions.data.length})</span
						>
					{/if}
				</h3>
				<Button
					size="sm"
					variant="outline"
					disabled={announcement.retired}
					aria-label={`Skip dates for ${announcement.title}`}
					onclick={() => (suppressionSheetOpen = true)}
				>
					<Plus class="size-4" aria-hidden="true" />Skip
				</Button>
			</div>
			{#if suppressions.isError}
				<Alert variant="destructive" class="mt-2">
					<AlertDescription
						>{apiErrorMessage(
							suppressions.error,
							"Could not load the skipped dates",
						)}</AlertDescription
					>
				</Alert>
			{:else if suppressions.isPending}
				<Skeleton class="mt-2 h-16 w-full" />
			{:else if suppressions.data.length === 0}
				<p class="mt-2 text-sm text-muted-foreground">No skipped dates.</p>
			{:else}
				{@const rows = suppressionRows(suppressions.data)}
				<ul class="mt-2 space-y-2">
					{#each rows.visible as suppression (suppression.id)}
						<li
							class="flex items-center justify-between gap-2 rounded-xl border border-border/70 px-3 py-2 text-sm"
						>
							<span class="min-w-0">
								<Ban
									class="mr-1.5 inline size-4 text-muted-foreground"
									aria-hidden="true"
								/>
								{suppressionRangeLabel(suppression)}
							</span>
							{#if confirming?.kind === "suppression" && confirming?.id === suppression.id}
								<span class="flex flex-none items-center gap-1">
									<Button
										size="sm"
										variant="destructive"
										disabled={removing}
										aria-label={`Confirm removing skip on ${suppressionRangeLabel(suppression)}`}
										onclick={confirmRemove}
									>
										{removing ? "Removing…" : "Confirm"}
									</Button>
									<Button
										size="sm"
										variant="ghost"
										disabled={removing}
										aria-label="Keep this skip"
										onclick={() => (confirming = null)}
									>
										Keep
									</Button>
								</span>
							{:else}
								<Button
									size="sm"
									variant="ghost"
									class="flex-none text-destructive"
									aria-label={`Remove skip on ${suppressionRangeLabel(suppression)}`}
									onclick={() => askRemove("suppression", suppression.id)}
								>
									<Trash2 class="size-4" aria-hidden="true" />Remove
								</Button>
							{/if}
						</li>
					{/each}
				</ul>
				{#if rows.hidden > 0}
					<p class="mt-1.5 text-xs text-muted-foreground">
						Showing {EXCEPTION_LIST_LIMIT} of {suppressions.data.length} skips.
						<button
							type="button"
							class="cursor-pointer font-semibold text-primary hover:underline"
							onclick={() => (showAllSuppressions = true)}
						>
							Show all
						</button>
					</p>
				{:else if showAllSuppressions}
					<p class="mt-1.5 text-xs text-muted-foreground">
						<button
							type="button"
							class="cursor-pointer font-semibold text-primary hover:underline"
							onclick={() => (showAllSuppressions = false)}
						>
							Show fewer
						</button>
					</p>
				{/if}
			{/if}
		</div>

		<div>
			<div class="flex items-center justify-between gap-2">
				<h3 class="text-sm font-bold">
					Text changes
					{#if overrides.data}
						<span class="font-medium text-muted-foreground"
							>({overrides.data.length})</span
						>
					{/if}
				</h3>
				<Button
					size="sm"
					variant="outline"
					disabled={announcement.retired}
					aria-label={`Change text for ${announcement.title}`}
					onclick={() => (overrideSheetOpen = true)}
				>
					<Plus class="size-4" aria-hidden="true" />Change text
				</Button>
			</div>
			{#if overrides.isError}
				<Alert variant="destructive" class="mt-2">
					<AlertDescription
						>{apiErrorMessage(
							overrides.error,
							"Could not load the text changes",
						)}</AlertDescription
					>
				</Alert>
			{:else if overrides.isPending}
				<Skeleton class="mt-2 h-16 w-full" />
			{:else if overrides.data.length === 0}
				<p class="mt-2 text-sm text-muted-foreground">
					No date-specific text changes.
				</p>
			{:else}
				{@const rows = overrideRows(overrides.data)}
				<ul class="mt-2 space-y-2">
					{#each rows.visible as override (override.id)}
						<li
							class="flex items-center justify-between gap-2 rounded-xl border border-border/70 px-3 py-2 text-sm"
						>
							<span class="min-w-0">
								<span class="block truncate font-semibold"
									>{overrideRangeLabel(override)}</span
								>
								<span class="text-xs text-muted-foreground"
									>{overrideSummary(override)}</span
								>
							</span>
							{#if confirming?.kind === "override" && confirming?.id === override.id}
								<span class="flex flex-none items-center gap-1">
									<Button
										size="sm"
										variant="destructive"
										disabled={removing}
										aria-label={`Confirm removing text change on ${overrideRangeLabel(override)}`}
										onclick={confirmRemove}
									>
										{removing ? "Removing…" : "Confirm"}
									</Button>
									<Button
										size="sm"
										variant="ghost"
										disabled={removing}
										aria-label="Keep this text change"
										onclick={() => (confirming = null)}
									>
										Keep
									</Button>
								</span>
							{:else}
								<Button
									size="sm"
									variant="ghost"
									class="flex-none text-destructive"
									aria-label={`Remove text change on ${overrideRangeLabel(override)}`}
									onclick={() => askRemove("override", override.id)}
								>
									<Trash2 class="size-4" aria-hidden="true" />Remove
								</Button>
							{/if}
						</li>
					{/each}
				</ul>
				{#if rows.hidden > 0}
					<p class="mt-1.5 text-xs text-muted-foreground">
						Showing {EXCEPTION_LIST_LIMIT} of {overrides.data.length} text changes.
						<button
							type="button"
							class="cursor-pointer font-semibold text-primary hover:underline"
							onclick={() => (showAllOverrides = true)}
						>
							Show all
						</button>
					</p>
				{:else if showAllOverrides}
					<p class="mt-1.5 text-xs text-muted-foreground">
						<button
							type="button"
							class="cursor-pointer font-semibold text-primary hover:underline"
							onclick={() => (showAllOverrides = false)}
						>
							Show fewer
						</button>
					</p>
				{/if}
			{/if}
		</div>
	</div>
</section>

{#if suppressionSheetOpen}
	<SuppressionSheet
		{announcement}
		{today}
		onClose={() => (suppressionSheetOpen = false)}
		onSaved={refreshExceptions}
	/>
{/if}

{#if overrideSheetOpen}
	<OverrideSheet
		{announcement}
		{today}
		onClose={() => (overrideSheetOpen = false)}
		onSaved={refreshExceptions}
	/>
{/if}
