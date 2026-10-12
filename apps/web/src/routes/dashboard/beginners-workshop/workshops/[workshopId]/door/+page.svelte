<!--
	ALE-379: a workshop's door view — what assigned Staff get: the header,
	then (ALE-390) door check-in and (ALE-391) Finish. The header follows the
	latest view a door command answers.
-->
<script lang="ts">
import { ArrowLeft, MapPin, Users } from "@lucide/svelte";
import { resolve } from "$app/paths";
import WorkshopAlerts from "#lib/components/beginners-workshops/workshop-alerts.svelte";
import {
	formatCivilDate,
	stageLabel,
	staffSummary,
} from "#lib/beginners-workshops/presentation.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import type { BeginnersWorkshopDoor } from "@dhc/api-client";
import { Button } from "#lib/components/ui/button/index.js";
import DoorCheckIn from "./door-check-in.svelte";

const { data } = $props();
// The load's view, until a door command answers a fresher one.
let workshop = $derived<BeginnersWorkshopDoor>(data.workshop);
</script>

<div class="flex w-full min-w-0 flex-col gap-6 py-4 sm:py-6">
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

	<header
		class="flex flex-wrap items-start justify-between gap-5 border-b pb-6"
		data-testid="door-header"
	>
		<div class="space-y-3">
			<p
				class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Beginners' Workshop · Door check-in
			</p>
			<h1 class="font-heading text-3xl sm:text-4xl">
				{formatCivilDate(workshop.date)} · {workshop.startTime}
			</h1>
			<p class="flex items-center gap-2 text-muted-foreground">
				<MapPin class="size-4 shrink-0" aria-hidden="true" />{workshop.venue}
			</p>
		</div>
		<div class="flex flex-col gap-3 lg:items-end">
			<div class="flex flex-wrap items-center gap-2">
				<Badge variant="outline">{stageLabel(workshop.stage)}</Badge>
				<WorkshopAlerts alerts={workshop.alerts} />
			</div>
			<p class="flex items-center gap-2 text-sm">
				<Users class="size-4 text-muted-foreground" />
				{staffSummary(workshop.staff)}
			</p>
		</div>
	</header>

	<DoorCheckIn door={data.workshop} onchange={(next) => (workshop = next)} />
</div>
