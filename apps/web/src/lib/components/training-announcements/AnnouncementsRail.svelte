<!--
	The Training Announcements rail (ALE-330): every scheduled Discord post
	about training, and the four commands that shape it — pause/resume, edit,
	retire, delete. It reads the list through the typed client and owns the
	lifecycle mutations; the calendar, exceptions and occurrence inspector
	arrive in ALE-331/332 on top of the same list.

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
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	useQueryClient,
} from "@tanstack/svelte-query";
import { Alert, AlertDescription, AlertTitle } from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import { Skeleton } from "$lib/components/ui/skeleton";
import { Switch } from "$lib/components/ui/switch";
import { Megaphone, Plus, TriangleAlert, X } from "@lucide/svelte";
import { apiErrorMessage } from "$lib/api-error";
import { toast } from "svelte-sonner";
import {
	type AnnouncementSave,
	warningMessages,
} from "$lib/training-announcements/announcement";
import AnnouncementCard from "./AnnouncementCard.svelte";
import AnnouncementSheet from "./AnnouncementSheet.svelte";

let { today }: { today: string } = $props();

const queryClient = useQueryClient();

let includeRetired = $state(false);
let sheetFor = $state<TrainingAnnouncement | null | undefined>(undefined);
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

function commandOptions(fallback: string, successMessage?: string) {
	return {
		onSuccess: () => {
			void refreshList();
			if (successMessage) toast.success(successMessage);
		},
		onError: (cause: TrainingAnnouncementError) => {
			toast.error(apiErrorMessage(cause, fallback));
		},
	};
}

const disable = createMutation(() => ({
	...trainingAnnouncementsDisableMutation(),
	...commandOptions("Could not pause this announcement"),
}));

const enable = createMutation(() => ({
	...trainingAnnouncementsEnableMutation(),
	...commandOptions("Could not resume this announcement"),
}));

const retire = createMutation(() => ({
	...trainingAnnouncementsRetireMutation(),
	...commandOptions("Could not retire this announcement"),
}));

const remove = createMutation(() => ({
	...trainingAnnouncementsDeleteMutation(),
	...commandOptions(
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
					Create the weekly roll call and sparring posts the club used to get
					from the retired Discord bot.
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
						onEdit={(row) => (sheetFor = row)}
						onRetire={retireAnnouncement}
						onDelete={deleteAnnouncement}
						onToggleEnabled={toggleEnabled}
					/>
				</li>
			{/each}
		</ul>
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
