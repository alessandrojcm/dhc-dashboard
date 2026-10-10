<!--
	The Email templates tab of Beginners' Workshops (ALE-383): every Intake
	Email type grouped by kind, and the selected type's editor. Templates are
	read and saved through the generated Phoenix client.
-->
<script lang="ts">
import {
	beginnersWorkshopEmailTemplatesListOptions,
	beginnersWorkshopEmailTemplatesListQueryKey,
	beginnersWorkshopEmailTemplatesUpdateMutation,
	type BeginnersWorkshopEmailTemplatesListResponse,
	type IntakeEmailTemplateUpdate,
	type IntakeEmailType,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	useQueryClient,
} from "@tanstack/svelte-query";
import { toast } from "svelte-sonner";
import { type ApiProblem, apiProblem } from "#lib/api-error.js";
import {
	INTAKE_EMAIL_KIND_GROUPS,
	INTAKE_EMAIL_TYPES,
} from "#lib/beginners-workshops/intake-emails/presentation.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Skeleton } from "#lib/components/ui/skeleton/index.js";
import { cn } from "#lib/utils.js";
import IntakeEmailTemplateEditor from "./intake-email-template-editor.svelte";

const queryClient = useQueryClient();
const templates = createQuery(() =>
	beginnersWorkshopEmailTemplatesListOptions(),
);

let selectedType = $state<IntakeEmailType | null>(null);
let problem = $state<ApiProblem | null>(null);

const rows = $derived(templates.data?.data ?? []);
const selected = $derived(
	rows.find((row) => row.emailType === selectedType) ?? rows[0],
);

const save = createMutation(() => ({
	...beginnersWorkshopEmailTemplatesUpdateMutation(),
	onSuccess: (response) => {
		problem = null;
		const saved = response.data;
		queryClient.setQueryData<BeginnersWorkshopEmailTemplatesListResponse>(
			beginnersWorkshopEmailTemplatesListQueryKey(),
			(current) =>
				current && {
					...current,
					data: current.data.map((row) =>
						row.emailType === saved.emailType ? saved : row,
					),
				},
		);
		toast.success(
			`${INTAKE_EMAIL_TYPES[saved.emailType].label} saved. Emails queued from now on use it.`,
		);
	},
	onError: (error) => {
		problem = apiProblem(error) ?? {
			detail: "The template could not be saved.",
			fields: [],
		};
	},
}));

function pick(type: IntakeEmailType) {
	selectedType = type;
	problem = null;
}

function onsave(draft: IntakeEmailTemplateUpdate) {
	if (!selected) return;
	save.mutate({ path: { emailType: selected.emailType }, body: draft });
}

const savedFormat = new Intl.DateTimeFormat("en-IE", {
	dateStyle: "medium",
	timeZone: "Europe/Dublin",
});
</script>

<div class="flex flex-col gap-5 py-2">
	<header>
		<h2 class="font-heading text-2xl">Intake Email templates</h2>
		<p class="text-sm text-muted-foreground">
			One club-wide template per email. Each workshop's details fill the
			placeholders, and the app adds the link button.
		</p>
	</header>

	{#if templates.isPending}
		<div class="grid gap-6 lg:grid-cols-[18rem_1fr]">
			<Skeleton class="h-96" />
			<Skeleton class="h-96" />
		</div>
	{:else if templates.isError}
		<Alert.Root variant="destructive">
			<Alert.Title>Templates unavailable</Alert.Title>
			<Alert.Description>
				{apiProblem(templates.error)?.detail ??
					"The templates could not be loaded."}
			</Alert.Description>
		</Alert.Root>
	{:else if selected}
		<div class="grid gap-6 lg:grid-cols-[18rem_1fr]">
			<nav class="flex flex-col gap-4" aria-label="Email types">
				{#each INTAKE_EMAIL_KIND_GROUPS as group (group.kind)}
					<section class="flex flex-col gap-1">
						<h3
							class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
						>
							{group.title}
						</h3>
						{#each rows.filter((row) => row.kind === group.kind) as row (row.emailType)}
							{@const copy = INTAKE_EMAIL_TYPES[row.emailType]}
							{@const current = row.emailType === selected.emailType}
							<Button
								type="button"
								variant={current ? "default" : "ghost"}
								class="h-auto flex-col items-start gap-0.5 px-3 py-2 text-left whitespace-normal"
								aria-current={current ? "true" : undefined}
								onclick={() => pick(row.emailType)}
							>
								<span class="font-medium">{copy.label}</span>
								<span
									class={cn(
										"text-xs font-normal",
										current
											? "text-primary-foreground/80"
											: "text-muted-foreground",
									)}
								>
									{copy.sentWhen} Saved {savedFormat.format(
										new Date(row.updatedAt),
									)}.
								</span>
							</Button>
						{/each}
					</section>
				{/each}
			</nav>

			{#key `${selected.emailType}:${selected.updatedAt}`}
				<IntakeEmailTemplateEditor
					template={selected}
					{onsave}
					saving={save.isPending}
					{problem}
				/>
			{/key}
		</div>
	{/if}
</div>
