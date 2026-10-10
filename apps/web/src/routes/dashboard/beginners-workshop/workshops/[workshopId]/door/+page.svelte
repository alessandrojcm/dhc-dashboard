<!--
	ALE-379: a workshop's door view — what assigned Staff get: the header,
	then (ALE-390) door check-in.
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
import DoorCheckIn from "./door-check-in.svelte";

const { data } = $props();
const workshop = $derived(data.workshop);
</script>

<div class="mx-auto flex max-w-md flex-col gap-4 py-4">
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

	<DoorCheckIn door={workshop} />
</div>
