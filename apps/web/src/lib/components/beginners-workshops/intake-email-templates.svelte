<!--
	The Email templates tab of Beginners' Workshops (ALE-383): every Intake
	Email type grouped by kind, with when it is sent and who receives it, and
	the selected type's editor. Templates are
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
import { Label } from "#lib/components/ui/label/index.js";
import * as NativeSelect from "#lib/components/ui/native-select/index.js";
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
		toast.success(`${saved.label} saved. Emails queued from now on use it.`);
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

const detailClass = (current: boolean) =>
	cn(
		"text-xs font-normal",
		current ? "text-foreground" : "text-muted-foreground",
	);
</script>

<div class="flex h-full min-h-0 flex-col gap-4 pb-1">
	<header class="shrink-0 border-b border-border px-1 py-4">
		<h2 class="font-heading text-2xl">Workshop emails</h2>
		<p class="mt-1 max-w-3xl text-sm leading-6 text-muted-foreground">
			One club-wide template per email. Each workshop's details fill the
			placeholders, and the app adds the link button.
		</p>
	</header>

	{#if templates.isPending}
		<div
			class="grid min-h-0 flex-1 gap-4 lg:grid-cols-[20rem_minmax(0,1fr)]"
			aria-label="Loading email templates"
			role="status"
		>
			<Skeleton class="hidden h-full lg:block" />
			<Skeleton class="h-full" />
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
		<div
			class="grid min-h-0 flex-1 grid-rows-[auto_minmax(0,1fr)] gap-4 lg:grid-cols-[20rem_minmax(0,1fr)] lg:grid-rows-1"
		>
			<div class="grid shrink-0 gap-2 lg:hidden">
				<Label for="intake-email-type">Email template</Label>
				<NativeSelect.Root
					id="intake-email-type"
					value={selected.emailType}
					onchange={(event) =>
						pick(event.currentTarget.value as IntakeEmailType)}
					class="w-full [&_select]:h-11"
				>
					{#each INTAKE_EMAIL_KIND_GROUPS as group (group.kind)}
						<NativeSelect.OptGroup label={group.title}>
							{#each rows.filter((row) => row.kind === group.kind) as row (row.emailType)}
								<NativeSelect.Option value={row.emailType}
									>{row.label}</NativeSelect.Option
								>
							{/each}
						</NativeSelect.OptGroup>
					{/each}
				</NativeSelect.Root>
			</div>
			<nav
				class="hidden min-h-0 flex-col gap-5 overflow-y-auto rounded-2xl border border-border bg-card p-3 lg:flex"
				aria-label="Email types"
			>
				{#each INTAKE_EMAIL_KIND_GROUPS as group (group.kind)}
					<section class="flex shrink-0 flex-col gap-2">
						<h3
							class="px-3 py-1 text-xs font-bold tracking-wider text-foreground uppercase"
						>
							{group.title}
						</h3>
						{#each rows.filter((row) => row.kind === group.kind) as row (row.emailType)}
							{@const copy = INTAKE_EMAIL_TYPES[row.emailType]}
							{@const current = row.emailType === selected.emailType}
							<Button
								type="button"
								variant="outline"
								class={cn(
									"h-auto w-full flex-col items-start gap-1 px-3 py-3 text-left whitespace-normal shadow-none hover:text-foreground",
									current
										? "border-primary bg-primary/10 text-foreground hover:bg-primary/15"
										: "border-transparent bg-transparent hover:border-border hover:bg-muted/50",
								)}
								aria-current={current ? "true" : undefined}
								onclick={() => pick(row.emailType)}
							>
								<span class="font-medium">{row.label}</span>
								<span class={detailClass(current)}>
									{copy.sentWhen}
								</span>
								<span class={detailClass(current)}>
									To: {copy.recipients}
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
