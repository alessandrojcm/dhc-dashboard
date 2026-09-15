<script lang="ts">
import {
	createMutation,
	createQuery,
	useQueryClient,
} from "@tanstack/svelte-query";
import {
	inventoryCatalogRequestLoanMutation,
	inventoryCatalogShowItemOptions,
	type InventoryOperatorItemValue,
} from "@dhc/api-client";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import DatePicker from "$lib/components/ui/date-picker.svelte";
import { Label } from "$lib/components/ui/label";
import { Skeleton } from "$lib/components/ui/skeleton";
import { Textarea } from "$lib/components/ui/textarea";
import {
	CalendarDays,
	Check,
	ClipboardCheck,
	MapPin,
	Package,
	RefreshCw,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";
import { getLocalTimeZone, parseDate, today } from "@internationalized/date";

let { slug }: { slug: string } = $props();

const queryClient = useQueryClient();
const itemQuery = createQuery(() => ({
	...inventoryCatalogShowItemOptions({ path: { slugOrId: slug } }),
	select: (response) => response.data,
}));

const todayValue = today(getLocalTimeZone());
const todayISO = todayValue.toString();
const weekOutISO = todayValue.add({ days: 7 }).toString();

let startsOn = $state(todayISO);
let dueOn = $state(weekOutISO);
let note = $state("");
let requestSent = $state(false);
const startsOnValue = $derived(parseDate(startsOn));
const dueOnValue = $derived(parseDate(dueOn));

const requestMutation = createMutation(() => ({
	...inventoryCatalogRequestLoanMutation(),
	onSuccess: () => {
		requestSent = true;
		queryClient.invalidateQueries({
			queryKey: ["inventoryCatalogShowItem"],
		});
		toast.success("Request sent — you'll hear back once reviewed.");
	},
	onError: (error) => {
		// SAFETY: Phoenix renders loan conflicts as `{ errors: { detail, code } }`;
		// only the stable `code` field is read to choose member-facing feedback.
		const code = (error.errors as { code?: string } | undefined)?.code;
		if (code === "duplicate_request") {
			toast.error("You already have a pending request for this item.");
		} else if (code === "item_unavailable") {
			toast.error("This item can't be requested right now.");
		} else {
			toast.error(error.errors?.detail ?? "Couldn't send the request.");
		}
	},
}));

function renderValue(value: InventoryOperatorItemValue): string | null {
	switch (value.valueType) {
		case "text":
			return value.text;
		case "decimal":
			return value.decimal;
		case "boolean":
			return value.boolean === null ? null : value.boolean ? "Yes" : "No";
		case "single_select":
			return value.optionLabel;
	}
}

function availabilityLabel(reason: string): string {
	switch (reason) {
		case "available":
			return "Available";
		case "on_loan":
			return "On loan";
		case "maintenance":
			return "Maintenance";
		default:
			return reason;
	}
}
</script>

<svelte:head>
	<title>
		{itemQuery.data
			? `${itemQuery.data.label} | Dublin HEMA Club`
			: "Equipment | Dublin HEMA Club"}
	</title>
</svelte:head>

{#if itemQuery.isPending}
	<div class="space-y-4" aria-label="Loading equipment">
		<Skeleton class="h-9 w-2/3" />
		<Skeleton class="h-5 w-1/3" />
		<div class="rounded-2xl border border-border bg-card p-5">
			<Skeleton class="h-5 w-full" />
			<Skeleton class="mt-2 h-5 w-2/3" />
		</div>
	</div>
{:else if itemQuery.isError}
	<Alert variant="destructive">
		<AlertDescription
			class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"
		>
			<span
				>{itemQuery.error.errors?.detail ?? "We couldn't load this item."}</span
			>
			<Button
				variant="outline"
				size="sm"
				class="min-h-10"
				onclick={() => itemQuery.refetch()}
			>
				<RefreshCw aria-hidden="true" />
				Try again
			</Button>
		</AlertDescription>
	</Alert>
{:else if itemQuery.data}
	{@const item = itemQuery.data}
	<section aria-labelledby="item-heading" class="space-y-5">
		<div class="border-b pb-5 pr-10">
			<div class="flex items-start justify-between gap-3">
				<div class="min-w-0">
					<p
						class="text-xs font-semibold uppercase tracking-[0.16em] text-primary"
					>
						Equipment details
					</p>
					<h1 id="item-heading" class="mt-1 font-heading text-2xl font-bold">
						{item.label}
					</h1>
				</div>
				<Badge
					variant={item.availability.available ? "secondary" : "outline"}
					class="shrink-0"
				>
					{availabilityLabel(item.availability.reason)}
				</Badge>
			</div>
			<div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
				<span class="text-muted-foreground">
					{item.category?.name ?? "Uncategorized"}
				</span>
				<span class="font-mono text-xs text-muted-foreground"
					>ID {item.slug}</span
				>
			</div>
		</div>

		{#if item.values.length > 0}
			<article class="inventory-panel p-5">
				<div class="flex gap-3">
					<div
						class="grid size-12 shrink-0 place-items-center rounded-xl bg-secondary/20 text-primary"
					>
						<Package class="size-6" aria-hidden="true" />
					</div>
					<dl class="min-w-0 flex-1 space-y-2">
						{#each item.values as value (value.definitionId)}
							{@const rendered = renderValue(value)}
							{#if rendered}
								<div class="flex items-baseline justify-between gap-3 text-sm">
									<dt class="text-muted-foreground">{value.definitionLabel}</dt>
									<dd class="text-right font-medium">{rendered}</dd>
								</div>
							{/if}
						{/each}
					</dl>
				</div>
			</article>
		{/if}

		{#if item.availability.available}
			<div class="rounded-2xl border border-primary/20 bg-primary/5 p-5">
				<div class="flex items-center gap-2">
					<CalendarDays class="size-5 text-primary" aria-hidden="true" />
					<h2 class="font-semibold">Request this item</h2>
				</div>
				{#if requestSent}
					<p
						class="mt-3 flex gap-2 text-sm text-emerald-700"
						aria-live="polite"
					>
						<Check class="mt-0.5 size-4 shrink-0" aria-hidden="true" />
						<span>
							Request sent. You'll receive the approved dates and collection
							location if an operator approves it — track it under
							<a class="font-semibold underline" href="/dashboard/my-loans">
								My loans
							</a>.
						</span>
					</p>
				{:else}
					<form
						onsubmit={(event) => {
							event.preventDefault();
							requestMutation.mutate({
								path: { slugOrId: item.slug },
								body: {
									startsOn,
									dueOn,
									...(note.trim() ? { note: note.trim() } : {}),
								},
							});
						}}
					>
						<div class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2">
							<div class="min-w-0 space-y-1">
								<Label for="collect-date" class="text-sm font-medium"
									>Collect</Label
								>
								<DatePicker
									id="collect-date"
									label="Collect"
									value={startsOnValue}
									minValue={todayValue}
									onValueChange={(value) => {
										if (value) {
											startsOn = value.toString();
											if (dueOn < startsOn) dueOn = startsOn;
										}
									}}
								/>
							</div>
							<div class="min-w-0 space-y-1">
								<Label for="return-date" class="text-sm font-medium"
									>Return</Label
								>
								<DatePicker
									id="return-date"
									label="Return"
									value={dueOnValue}
									minValue={startsOnValue}
									onValueChange={(value) => {
										if (value) dueOn = value.toString();
									}}
								/>
							</div>
						</div>
						<div class="mt-3">
							<Label for="request-note" class="text-sm font-medium">
								Note <span class="font-normal text-muted-foreground"
									>(optional)</span
								>
							</Label>
							<Textarea
								id="request-note"
								class="mt-1"
								rows={2}
								maxlength={500}
								placeholder="Training or event use"
								bind:value={note}
							/>
						</div>
						{#if requestMutation.isError}
							{@const detail =
								(
									requestMutation.error.errors as
										{ detail?: string } | undefined
								)?.detail ?? "Couldn't send the request."}
							<p class="mt-3 text-sm text-destructive" aria-live="polite">
								{detail}
							</p>
						{/if}
						<Button
							type="submit"
							class="mt-4 min-h-12 w-full text-base"
							disabled={requestMutation.isPending}
						>
							<ClipboardCheck class="size-5" aria-hidden="true" />
							{requestMutation.isPending ? "Sending…" : "Send request"}
						</Button>
					</form>
				{/if}
			</div>
		{:else}
			<p
				class="flex gap-2 rounded-2xl border border-border bg-muted/40 p-4 text-sm text-muted-foreground"
			>
				<MapPin class="size-4 shrink-0 text-primary" aria-hidden="true" />
				<span>
					This item isn't requestable right now — it's either on loan or being
					serviced. It stays visible so you don't have to guess.
				</span>
			</p>
		{/if}
	</section>
{/if}
