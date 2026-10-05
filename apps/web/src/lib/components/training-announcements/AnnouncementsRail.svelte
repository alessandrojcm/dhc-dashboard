<!--
	The Training Announcements rail (ALE-330) plus the selected
	announcement's detail column (ALE-331), the Month/Week calendar of every
	occurrence in view (ALE-332) and the occurrence inspector (ALE-333):
	every scheduled Discord post about training, the four lifecycle
	commands, and — once a card's "Dates & copy" action picks one — its next
	post by resolved title with the capped Suppression and Override lists.
	It reads the list through the typed client and owns the lifecycle
	mutations; a calendar chip opens the inspector on the item's payload
	while jumping the rail to its announcement.

	Advisory `warnings[]` from a create or schedule edit are shown here rather
	than in the sheet: the write already committed, so the notice must not look
	like a failure and must not be dismissed by closing a form.
-->
<script lang="ts">
import {
	trainingAnnouncementsDeleteMutation,
	trainingAnnouncementsDisableMutation,
	trainingAnnouncementsEnableMutation,
	trainingAnnouncementsListOptions,
	trainingAnnouncementsListQueryKey,
	trainingAnnouncementsRetireMutation,
	type TrainingAnnouncement,
	type TrainingAnnouncementError,
	type TrainingAnnouncementListResponse,
	type TrainingAnnouncementOccurrence,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	useQueryClient,
	type QueryKey,
} from "@tanstack/svelte-query";
import {
	applyLifecycle,
	listIncludesRetired,
	type LifecycleCommand,
} from "$lib/training-announcements/optimistic";
import { Alert, AlertDescription, AlertTitle } from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import { Skeleton } from "$lib/components/ui/skeleton";
import { Switch } from "$lib/components/ui/switch";
import { Megaphone, Plus, TriangleAlert, X } from "@lucide/svelte";
import { apiErrorMessage } from "$lib/api-error";
import { toast } from "svelte-sonner";
import { tick } from "svelte";
import {
	type AnnouncementSave,
	warningMessages,
} from "$lib/training-announcements/announcement";
import AnnouncementCard from "./AnnouncementCard.svelte";
import AnnouncementDetail from "./AnnouncementDetail.svelte";
import AnnouncementSheet from "./AnnouncementSheet.svelte";
import OccurrenceInspector from "./OccurrenceInspector.svelte";
import TrainingCalendar from "./TrainingCalendar.svelte";

let { today }: { today: string } = $props();

const queryClient = useQueryClient();

let includeRetired = $state(false);
let sheetFor = $state<TrainingAnnouncement | null | undefined>(undefined);
let selectedId = $state<string | null>(null);
let detailPanel: HTMLElement | undefined = $state();
let inspected = $state<TrainingAnnouncementOccurrence | null>(null);
let notices = $state<{ title: string; messages: string[] }[]>([]);

const announcements = createQuery(() => ({
	...trainingAnnouncementsListOptions({ query: { includeRetired } }),
	select: (response) => response.data,
}));

function refreshList() {
	return queryClient.invalidateQueries({
		queryKey: trainingAnnouncementsListQueryKey(),
	});
}

const selected = $derived(
	announcements.data?.find((row) => row.id === selectedId) ?? null,
);

/**
 * Lifecycle commands are optimistic: every cached list shows the predicted
 * row the moment the command is sent, is restored if Phoenix refuses it, and
 * is refetched once it settles so Phoenix's row replaces the prediction.
 */
function commandOptions(
	command: LifecycleCommand,
	fallback: string,
	successMessage?: string,
) {
	const lists = { queryKey: trainingAnnouncementsListQueryKey() };
	return {
		onMutate: async (variables: { path: { id: string } }) => {
			// An in-flight list read would land on top of the prediction.
			await queryClient.cancelQueries(lists);
			const previous =
				queryClient.getQueriesData<TrainingAnnouncementListResponse>(lists);
			for (const [key, data] of previous) {
				if (!data) continue;
				queryClient.setQueryData<TrainingAnnouncementListResponse>(key, {
					...data,
					data: applyLifecycle(
						data.data,
						variables.path.id,
						command,
						listIncludesRetired(key),
					),
				});
			}
			return { previous };
		},
		onError: (
			cause: TrainingAnnouncementError,
			_variables: unknown,
			context: { previous: [QueryKey, unknown][] } | undefined,
		) => {
			for (const [key, data] of context?.previous ?? [])
				queryClient.setQueryData(key, data);
			toast.error(apiErrorMessage(cause, fallback));
		},
		onSuccess: () => {
			if (successMessage) toast.success(successMessage);
		},
		onSettled: () => refreshList(),
	};
}

const disable = createMutation(() => ({
	...trainingAnnouncementsDisableMutation(),
	...commandOptions("disable", "Could not pause this announcement"),
}));

const enable = createMutation(() => ({
	...trainingAnnouncementsEnableMutation(),
	...commandOptions("enable", "Could not resume this announcement"),
}));

const retire = createMutation(() => ({
	...trainingAnnouncementsRetireMutation(),
	...commandOptions("retire", "Could not retire this announcement"),
}));

const remove = createMutation(() => ({
	...trainingAnnouncementsDeleteMutation(),
	...commandOptions(
		"delete",
		"Could not delete this announcement",
		"Announcement deleted.",
	),
}));

const busy = $derived(
	disable.isPending || enable.isPending || retire.isPending || remove.isPending,
);

function toggleEnabled(announcement: TrainingAnnouncement, enabled: boolean) {
	const mutate = enabled ? enable.mutate : disable.mutate;
	mutate({ path: { id: announcement.id } });
}

function retireAnnouncement(announcement: TrainingAnnouncement) {
	retire.mutate({ path: { id: announcement.id } });
}

function deleteAnnouncement(announcement: TrainingAnnouncement) {
	remove.mutate({ path: { id: announcement.id } });
}

async function selectAnnouncement(announcement: TrainingAnnouncement) {
	selectedId = announcement.id;
	await tick();
	detailPanel?.focus({ preventScroll: true });
	detailPanel?.scrollIntoView({ block: "start" });
}

/**
 * A calendar chip was picked: jump the rail to its announcement and open
 * the occurrence inspector on the item's payload. Holiday announcements are
 * read-only items with no announcement, so they select nothing but still
 * open the inspector.
 */
function selectCalendarItem(item: TrainingAnnouncementOccurrence) {
	if (item.announcementId !== null) selectedId = item.announcementId;
	inspected = item;
}

const inspectedAnnouncement = $derived(
	inspected?.announcementId
		? (announcements.data?.find(
				(row) => row.id === inspected?.announcementId,
			) ?? null)
		: null,
);

function saved(save: AnnouncementSave) {
	if (save.warnings.length === 0) {
		toast.success("Announcement saved.");
		return;
	}
	notices = [
		...notices,
		{
			title: `"${save.announcement.title}" saved with warnings`,
			messages: warningMessages(save.warnings),
		},
	];
}
</script>

<div class="space-y-4">
	<div class="flex flex-wrap items-center justify-between gap-3">
		<Button onclick={() => (sheetFor = null)}>
			<Plus aria-hidden="true" /> New announcement
		</Button>
		<label class="flex cursor-pointer items-center gap-2 text-sm font-semibold">
			Show retired
			<Switch
				checked={includeRetired}
				aria-label="Show retired"
				onCheckedChange={(checked) => {
					includeRetired = checked;
				}}
			/>
		</label>
	</div>

	{#each notices as notice, index (notice)}
		<Alert data-testid="announcement-warning">
			<TriangleAlert aria-hidden="true" />
			<AlertTitle>{notice.title}</AlertTitle>
			<AlertDescription>
				<ul class="list-disc space-y-1 pl-4">
					{#each notice.messages as message (message)}
						<li>{message}</li>
					{/each}
				</ul>
			</AlertDescription>
			<Button
				size="icon"
				variant="ghost"
				aria-label="Dismiss warning"
				onclick={() => {
					notices = notices.filter((_, at) => at !== index);
				}}
			>
				<X aria-hidden="true" />
			</Button>
		</Alert>
	{/each}

	{#if announcements.isError}
		<Alert variant="destructive">
			<AlertDescription class="flex items-center justify-between gap-4">
				<span
					>{apiErrorMessage(
						announcements.error,
						"Could not load the announcements",
					)}</span
				>
				<Button variant="outline" onclick={() => announcements.refetch()}
					>Try again</Button
				>
			</AlertDescription>
		</Alert>
	{:else if announcements.isPending}
		<div class="space-y-3">
			<Skeleton class="h-36 w-full" />
			<Skeleton class="h-36 w-full" />
		</div>
	{:else if announcements.data.length === 0}
		<div
			class="flex flex-col items-center gap-3 rounded-2xl border border-dashed border-border/80 px-6 py-12 text-center"
		>
			<Megaphone class="size-8 text-muted-foreground" aria-hidden="true" />
			<div>
				<p class="font-semibold">No announcements yet</p>
				<p class="mt-1 text-sm text-muted-foreground">
					Create an announcement to schedule a Discord post.
				</p>
			</div>
			<Button variant="outline" onclick={() => (sheetFor = null)}>
				<Plus aria-hidden="true" /> New announcement
			</Button>
		</div>
	{:else}
		<ul class="grid gap-3 lg:grid-cols-2">
			{#each announcements.data as announcement (announcement.id)}
				<li>
					<AnnouncementCard
						{announcement}
						{busy}
						selected={selectedId === announcement.id}
						onSelect={selectAnnouncement}
						onEdit={(row) => (sheetFor = row)}
						onRetire={retireAnnouncement}
						onDelete={deleteAnnouncement}
						onToggleEnabled={toggleEnabled}
					/>
				</li>
			{/each}
		</ul>
		{#if selected}
			<section
				bind:this={detailPanel}
				id="announcement-dates-and-copy"
				aria-label={`Manage posts for ${selected.title}`}
				tabindex="-1"
				class="scroll-mt-20 rounded-2xl focus-visible:outline-2 focus-visible:outline-ring"
			>
				{#key selected.id}
					<AnnouncementDetail
						announcement={selected}
						{today}
						onEdit={(row) => (sheetFor = row)}
					/>
				{/key}
			</section>
		{/if}
		<TrainingCalendar {today} onSelectItem={selectCalendarItem} />
	{/if}
</div>

{#if sheetFor !== undefined}
	<AnnouncementSheet
		announcement={sheetFor}
		{today}
		onClose={() => (sheetFor = undefined)}
		onSaved={saved}
	/>
{/if}

{#if inspected}
	<OccurrenceInspector
		item={inspected}
		{today}
		announcement={inspectedAnnouncement}
		onClose={() => (inspected = null)}
	/>
{/if}
