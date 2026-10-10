<!--
	ALE-379: a workshop's door view — what assigned Staff get. The header
	only for now; the roster and check-in arrive with door check-in.
-->
<script lang="ts">
import { ArrowLeft, Users } from "@lucide/svelte";
import { resolve } from "$app/paths";
import WorkshopAlerts from "#lib/components/beginners-workshops/workshop-alerts.svelte";
import {
	formatCivilDate,
	stageLabel,
	staffSummary,
} from "#lib/beginners-workshops/presentation.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Empty from "#lib/components/ui/empty/index.js";

const { data } = $props();
const workshop = $derived(data.workshop);
</script>

<div class="mx-auto flex max-w-2xl flex-col gap-6 py-4">
	<Button
		variant="ghost"
		size="sm"
		class="w-fit"
		href={data.canManageWorkshops
			? resolve("/dashboard/beginners-workshop")
			: resolve("/dashboard/my-beginners-workshops")}
	>
		<ArrowLeft />
		{data.canManageWorkshops ? "Workshops" : "My Beginners' Workshops"}
	</Button>

	<header class="flex flex-col gap-2" data-testid="door-header">
		<p class="text-xs font-bold tracking-wider text-muted-foreground uppercase">
			Door
		</p>
		<h1 class="font-heading text-3xl">
			{formatCivilDate(workshop.date)} · {workshop.startTime}
		</h1>
		<p class="text-muted-foreground">{workshop.venue}</p>
		<div class="flex flex-wrap items-center gap-2">
			<Badge variant="outline">{stageLabel(workshop.stage)}</Badge>
			<WorkshopAlerts alerts={workshop.alerts} />
		</div>
		<p class="flex items-center gap-2 text-sm">
			<Users class="size-4 text-muted-foreground" />
			{staffSummary(workshop.staff)}
		</p>
	</header>

	<Empty.Root class="border">
		<Empty.Header>
			<Empty.Title>No door list yet</Empty.Title>
			<Empty.Description>
				The people coming to this workshop will be listed here for check-in.
			</Empty.Description>
		</Empty.Header>
	</Empty.Root>
</div>
