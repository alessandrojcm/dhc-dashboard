<!-- PROTOTYPE — throwaway (ALE-372). Beginners' Workshops index: several can be
     scheduled at once. The fixture has one workshop per lifecycle moment. -->
<script lang="ts">
import {
	AlertTriangle,
	CalendarPlus,
	ChevronRight,
	DoorOpen,
	Users,
} from "@lucide/svelte";
import dayjs from "dayjs";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import { cn } from "#lib/utils.js";
import { go } from "./bw-nav";
import {
	euro,
	fmtTime,
	NOW,
	proto,
	type Workshop,
} from "./bw-prototype-store.svelte";
import SeatMeter from "./seat-meter.svelte";

const upcoming = $derived(
	proto.visibleWorkshops().filter((w) => w.status === "scheduled"),
);
const past = $derived(
	proto
		.visibleWorkshops()
		.filter((w) => w.status !== "scheduled")
		.reverse(),
);
const manage = $derived(proto.viewer === "coordinator");

function phaseTone(w: Workshop) {
	switch (proto.phase(w)) {
		case "next_batch_ready":
		case "no_batch":
			return "border-secondary bg-secondary/25";
		case "check_in_open":
			return "border-emerald-700 bg-emerald-600 text-white";
		case "cancelled":
			return "border-destructive/50 text-destructive";
		default:
			return "";
	}
}
</script>

{#snippet row(w: Workshop)}
	{@const alerts = proto.alerts(w)}
	<li>
		<button
			type="button"
			class="group grid w-full cursor-pointer grid-cols-[4.5rem_1fr] items-center gap-4 rounded-2xl border border-border bg-card p-4 text-left shadow-[4px_4px_0_rgb(18_24_39/12%)] transition hover:-translate-y-0.5 hover:border-primary sm:grid-cols-[4.5rem_1fr_14rem_auto]"
			onclick={() => go(manage ? "console" : "door", w.id)}
		>
			<div
				class={cn(
					"flex flex-col items-center rounded-xl border-2 py-2",
					dayjs(w.date).isSame(NOW, "day")
						? "border-emerald-700 bg-emerald-50"
						: "border-primary/30",
				)}
			>
				<span
					class="text-xs font-bold tracking-widest text-muted-foreground uppercase"
					>{dayjs(w.date).format("ddd")}</span
				>
				<span class="font-heading text-2xl leading-none"
					>{dayjs(w.date).format("D")}</span
				>
				<span class="text-xs font-semibold uppercase"
					>{dayjs(w.date).format("MMM")}</span
				>
			</div>
			<div class="flex min-w-0 flex-col gap-1.5">
				<div class="flex flex-wrap items-center gap-2">
					<span class="font-semibold"
						>{fmtTime(`${w.date}T${w.startTime}`)}</span
					>
					<Badge variant="outline" class={phaseTone(w)}
						>{proto.phaseLabel(w)}</Badge
					>
					{#each alerts.filter((alert) => alert.tone !== "info") as alert (alert.text)}
						<Badge
							variant="outline"
							class={alert.tone === "error"
								? "border-destructive bg-destructive text-white"
								: "border-amber-500 bg-amber-50 text-amber-900"}
						>
							<AlertTriangle />
							{alert.text}
						</Badge>
					{/each}
				</div>
				<p class="truncate text-sm text-muted-foreground">
					{w.venue}{manage ? ` · ${euro(w.fee)}` : ""}
				</p>
				<p class="flex items-center gap-1.5 text-xs text-muted-foreground">
					<Users class="size-3.5" />
					{proto.staffName(w.coachId) ?? "No coach"}{w.assistantIds.length
						? ` + ${w.assistantIds.map((id) => proto.staffName(id)?.split(" ")[0]).join(", ")}`
						: ""}
				</p>
			</div>
			<div class="col-span-2 sm:col-span-1">
				{#if w.status !== "cancelled"}<SeatMeter workshop={w} compact />{/if}
			</div>
			<ChevronRight
				class="hidden size-5 text-muted-foreground transition group-hover:translate-x-0.5 sm:block"
			/>
		</button>
	</li>
{/snippet}

<div class="flex flex-col gap-6">
	{#if manage}
		<nav
			class="flex flex-wrap items-center gap-1 rounded-xl bg-muted p-1 text-sm"
			aria-label="Beginners Workshop sections (prototype IA)"
		>
			<span class="rounded-lg px-3 py-1.5 text-muted-foreground">Dashboard</span
			>
			<span
				class="rounded-lg px-3 py-1.5 text-muted-foreground"
				title="Existing page. Loses its Invite and resend actions (ALE-371); its capability becomes beginners.waitlist.manage, without coach"
				>Waitlist</span
			>
			<span class="rounded-lg bg-background px-3 py-1.5 font-semibold shadow-sm"
				>Workshops</span
			>
			<button
				type="button"
				class="cursor-pointer rounded-lg px-3 py-1.5 text-muted-foreground hover:bg-background"
				onclick={() => go("invitable")}
				>Invitable <Badge variant="outline" class="ml-1"
					>{proto.invitable().length}</Badge
				></button
			>
			<button
				type="button"
				class="cursor-pointer rounded-lg px-3 py-1.5 text-muted-foreground hover:bg-background"
				onclick={() => go("templates")}>Email templates</button
			>
		</nav>
	{/if}

	<header class="flex flex-wrap items-end justify-between gap-4">
		<div>
			<h1 class="font-heading text-3xl">
				{manage ? "Beginners' Workshops" : "My Beginners' Workshops"}
			</h1>
			<p class="text-sm text-muted-foreground">
				{manage
					? "Never listed publicly. Seats come from the Waitlist through Batches."
					: "Workshops you're assigned to. Open one to check people in at the door."}
			</p>
		</div>
		{#if manage}
			<Button
				onclick={() => {
					proto.dialog = { kind: "schedule" };
				}}><CalendarPlus /> Schedule workshop</Button
			>
		{/if}
	</header>

	<section class="flex flex-col gap-3">
		<h2
			class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
		>
			Upcoming
		</h2>
		<ul class="flex flex-col gap-3">
			{#each upcoming as w (w.id)}{@render row(w)}{/each}
		</ul>
	</section>

	{#if manage && past.length}
		<section class="flex flex-col gap-3">
			<h2
				class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
			>
				Past and cancelled
			</h2>
			<ul class="flex flex-col gap-3 opacity-90">
				{#each past as w (w.id)}{@render row(w)}{/each}
			</ul>
		</section>
	{/if}

	{#if !manage}
		<p class="flex items-center gap-2 text-sm text-muted-foreground">
			<DoorOpen class="size-4" /> Assigned staff open straight into the door view.
		</p>
	{/if}
</div>
