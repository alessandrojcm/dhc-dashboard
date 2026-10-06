<!--
	One Training Announcement in the rail (ALE-330): what it is, whether its
	occurrences post, and the three lifecycle actions the API offers. Pure
	presentation — every command is the rail's mutation, and Phoenix re-decides
	under its own guards, so this card only pre-empts the delete rule it can
	explain.

	ALE-332: the card also shows the announcement's next posts and recent
	deliveries from `listForAnnouncement`, labelled with the shared status
	vocabulary so cards, calendar chips and the inspector agree.
-->
<script lang="ts">
import {
	trainingAnnouncementOccurrencesListForAnnouncementOptions,
	type TrainingAnnouncement,
} from "@dhc/api-client";
import { createQuery } from "@tanstack/svelte-query";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Skeleton } from "#lib/components/ui/skeleton/index.js";
import { Switch } from "#lib/components/ui/switch/index.js";
import { CalendarDays, Pencil, Trash2 } from "@lucide/svelte";
import "./occurrence-tone.css";
import { KIND_LABELS } from "#lib/training-announcements/copy.js";
import {
	ANNOUNCEMENT_LIFECYCLE_LABELS,
	announcementDateLabel,
	announcementLifecycle,
	deleteBlockedReason,
	scheduleLabel,
} from "#lib/training-announcements/announcement.js";
import { occurrenceStatus } from "#lib/training-announcements/status.js";

let {
	announcement,
	onEdit,
	onRetire,
	onDelete,
	onToggleEnabled,
	onSelect,
	selected = false,
	busy = false,
}: {
	announcement: TrainingAnnouncement;
	onEdit: (announcement: TrainingAnnouncement) => void;
	onRetire: (announcement: TrainingAnnouncement) => void;
	onDelete: (announcement: TrainingAnnouncement) => void;
	onToggleEnabled: (
		announcement: TrainingAnnouncement,
		enabled: boolean,
	) => void;
	onSelect: (announcement: TrainingAnnouncement) => void;
	selected?: boolean;
	busy?: boolean;
} = $props();

const lifecycle = $derived(announcementLifecycle(announcement));
const deleteReason = $derived(deleteBlockedReason(announcement));

const upcoming = createQuery(() => ({
	...trainingAnnouncementOccurrencesListForAnnouncementOptions({
		path: { id: announcement.id },
		query: { direction: "upcoming", limit: 3 },
	}),
	select: (response) => response.data,
}));

const recent = createQuery(() => ({
	...trainingAnnouncementOccurrencesListForAnnouncementOptions({
		path: { id: announcement.id },
		query: { direction: "recent", limit: 3 },
	}),
	select: (response) => response.data,
}));
</script>

<article
	class="rounded-2xl border border-border/80 bg-card p-4 shadow-sm transition-colors hover:border-primary/30"
	class:border-primary={selected}
	class:ring-1={selected}
	class:ring-primary={selected}
	class:opacity-70={lifecycle === "retired"}
>
	<div class="flex items-start justify-between gap-3">
		<div class="min-w-0">
			<p
				class="text-[0.6875rem] font-bold tracking-[0.12em] text-muted-foreground uppercase"
			>
				{KIND_LABELS[announcement.kind]} ·
				{announcement.weekday === null ? "one-off" : "weekly"}
			</p>
			<h3 class="mt-0.5 truncate font-semibold">{announcement.title}</h3>
			<p class="mt-1 text-sm text-muted-foreground">
				{scheduleLabel(announcement)}
			</p>
			<p class="text-sm text-muted-foreground">
				{announcement.mentionEveryone
					? "Notifies @everyone"
					: "No @everyone notification"}
			</p>
		</div>
		<Badge variant={lifecycle === "live" ? "default" : "outline"}>
			{ANNOUNCEMENT_LIFECYCLE_LABELS[lifecycle]}
		</Badge>
	</div>

	<div class="mt-4 flex flex-wrap items-center gap-2">
		<Switch
			checked={announcement.enabled}
			disabled={busy || lifecycle === "retired"}
			aria-label={`Posting for ${announcement.title}`}
			onCheckedChange={(enabled) => onToggleEnabled(announcement, enabled)}
		/>
		<Button
			size="sm"
			variant={selected ? "default" : "outline"}
			aria-label={`Manage posts for ${announcement.title}`}
			aria-expanded={selected}
			aria-controls={selected ? "announcement-dates-and-copy" : undefined}
			onclick={() => onSelect(announcement)}
		>
			<CalendarDays class="size-4" aria-hidden="true" />Manage posts
		</Button>
		<Button
			size="sm"
			variant="outline"
			disabled={busy || lifecycle === "retired"}
			aria-label={`Edit ${announcement.title}`}
			onclick={() => onEdit(announcement)}
		>
			<Pencil class="size-4" aria-hidden="true" />Edit
		</Button>
		<Button
			size="sm"
			variant="ghost"
			disabled={busy || lifecycle === "retired"}
			aria-label={`Retire ${announcement.title}`}
			onclick={() => onRetire(announcement)}
		>
			Retire
		</Button>
		<Button
			size="sm"
			variant="ghost"
			class="text-destructive"
			disabled={busy || deleteReason !== undefined}
			aria-label={`Delete ${announcement.title}`}
			onclick={() => onDelete(announcement)}
		>
			<Trash2 class="size-4" aria-hidden="true" />Delete
		</Button>
	</div>

	{#if deleteReason}
		<p class="mt-2 text-xs text-muted-foreground">{deleteReason}</p>
	{/if}

	<div class="mt-4 grid gap-3 border-t border-border/60 pt-3 sm:grid-cols-2">
		<div>
			<h4
				class="text-[0.6875rem] font-bold tracking-[0.12em] text-muted-foreground uppercase"
			>
				Next posts
			</h4>
			{#if upcoming.isPending}
				<Skeleton class="mt-1.5 h-8 w-full" />
			{:else if upcoming.isError}
				<p class="mt-1.5 text-xs text-muted-foreground">
					Could not load the next posts.
				</p>
			{:else if upcoming.data.length === 0}
				<p class="mt-1.5 text-xs text-muted-foreground">No upcoming post.</p>
			{:else}
				<ul class="mt-1.5 space-y-1.5" data-testid="card-next-posts">
					{#each upcoming.data as occurrence (occurrence.date)}
						{@const status = occurrenceStatus(occurrence)}
						<li class="min-w-0 text-xs">
							<span class="block truncate font-semibold"
								>{occurrence.threadName ??
									announcementDateLabel(occurrence.date)}</span
							>
							<span
								class="mt-0.5 flex items-center gap-1.5 text-muted-foreground"
							>
								<span>{announcementDateLabel(occurrence.date)}</span>
								<span class="ta-pill ta-tone--{status.tone}">
									<span class="ta-pill-dot" aria-hidden="true"></span>
									{status.label}
								</span>
							</span>
						</li>
					{/each}
				</ul>
			{/if}
		</div>
		<div>
			<h4
				class="text-[0.6875rem] font-bold tracking-[0.12em] text-muted-foreground uppercase"
			>
				Recent
			</h4>
			{#if recent.isPending}
				<Skeleton class="mt-1.5 h-8 w-full" />
			{:else if recent.isError}
				<p class="mt-1.5 text-xs text-muted-foreground">
					Could not load recent deliveries.
				</p>
			{:else if recent.data.length === 0}
				<p class="mt-1.5 text-xs text-muted-foreground">No posts yet.</p>
			{:else}
				<ul class="mt-1.5 space-y-1.5" data-testid="card-recent">
					{#each recent.data as occurrence (occurrence.date)}
						{@const status = occurrenceStatus(occurrence)}
						<li class="min-w-0 text-xs">
							<span class="block truncate font-semibold"
								>{occurrence.threadName ??
									announcementDateLabel(occurrence.date)}</span
							>
							<span
								class="mt-0.5 flex items-center justify-between gap-1.5 text-muted-foreground"
							>
								<span>{announcementDateLabel(occurrence.date)}</span>
								<span class="ta-pill ta-tone--{status.tone}">
									<span class="ta-pill-dot" aria-hidden="true"></span>
									{status.label}
								</span>
							</span>
						</li>
					{/each}
				</ul>
			{/if}
		</div>
	</div>
</article>

<style>
.ta-pill {
	display: inline-flex;
	flex: none;
	align-items: center;
	gap: 0.3rem;
	border: 1px solid hsl(var(--border) / 0.8);
	border-radius: 9999px;
	background: hsl(var(--muted) / 0.35);
	padding: 0.1rem 0.45rem;
	font-size: 0.625rem;
	font-weight: 800;
	letter-spacing: 0.02em;
	white-space: nowrap;
}

.ta-pill-dot {
	width: 0.4rem;
	height: 0.4rem;
	flex: none;
	border-radius: 9999px;
	background: var(--ta-tone, hsl(var(--muted-foreground)));
}
</style>
