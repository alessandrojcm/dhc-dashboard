<!--
	One Training Announcement in the rail (ALE-330): what it is, whether its
	occurrences post, and the three lifecycle actions the API offers. Pure
	presentation — every command is the rail's mutation, and Phoenix re-decides
	under its own guards, so this card only pre-empts the delete rule it can
	explain.
-->
<script lang="ts">
import type { TrainingAnnouncement } from "@dhc/api-client";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Switch } from "$lib/components/ui/switch";
import { CalendarDays, Pencil, Trash2 } from "@lucide/svelte";
import { KIND_LABELS } from "$lib/training-announcements/copy";
import {
	ANNOUNCEMENT_LIFECYCLE_LABELS,
	announcementLifecycle,
	deleteBlockedReason,
	scheduleLabel,
} from "$lib/training-announcements/announcement";

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
				{scheduleLabel(announcement)} · Europe/Dublin
			</p>
			<p class="text-sm text-muted-foreground">
				{announcement.mentionEveryone
					? "Pings @everyone"
					: "No ping — only the bot posts"}
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
			aria-label={`Dates and copy for ${announcement.title}`}
			aria-pressed={selected}
			onclick={() => onSelect(announcement)}
		>
			<CalendarDays class="size-4" aria-hidden="true" />Dates & copy
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
</article>
