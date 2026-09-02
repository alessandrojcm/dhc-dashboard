<script lang="ts">
import { page } from "$app/state";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Textarea } from "$lib/components/ui/textarea";
import PrototypeVariantSwitcher from "$lib/components/prototype/PrototypeVariantSwitcher.svelte";
import {
	ArrowLeft,
	ArrowRight,
	CalendarDays,
	Check,
	ClipboardCheck,
	Clock3,
	MapPin,
	Package,
	QrCode,
	Search,
	ShieldAlert,
	Wrench,
} from "@lucide/svelte";

// PROTOTYPE — ALE-276. Three mobile workflow variations, switchable via
// ?variant=member|queue|scan. Uses local sample data only; do not connect it
// to a production mutation or treat it as a finished inventory UI.

const variants = [
	{ id: "member", label: "A — Member request" },
	{ id: "queue", label: "B — Handover queue" },
	{ id: "scan", label: "C — Scan-led operations" },
];
const variant = $derived(
	variants.some(
		(candidate) => candidate.id === page.url.searchParams.get("variant"),
	)
		? (page.url.searchParams.get("variant") ?? "member")
		: "member",
);

type LoanStatus = "requested" | "approved" | "checked_out" | "returned";
let requestSubmitted = $state(false);
let selectedLoanStatus = $state<LoanStatus>("requested");
let selectedItem = $state("Feder 01H4M8");
let scanOpen = $state(false);
let maintenanceStarted = $state(false);
let maintenanceReason = $state("");
let maintenanceNote = $state("");
let moveRecorded = $state(false);
let approvalOpen = $state(false);
let competingRequestResolved = $state(false);

const item = {
	label: "Regenyei Longsword · medium",
	slug: "feder-01H4M8",
	category: "Longsword feder",
	properties: ["Medium flex", "Black grip", "Steel crossguard"],
	container: "Main hall › Weapon rack B › Slot 12",
};

const activeLoans: {
	member: string;
	item: string;
	due: string;
	status: LoanStatus;
}[] = $derived([
	{
		member: "Aoife Murphy",
		item: "Regenyei Longsword · medium",
		due: "Fri 5 Sep",
		status: selectedLoanStatus,
	},
	{
		member: "Rory Byrne",
		item: "Mask · 1600N",
		due: "Thu 4 Sep",
		status: "checked_out",
	},
]);

function advanceLoan() {
	selectedLoanStatus =
		selectedLoanStatus === "requested"
			? "approved"
			: selectedLoanStatus === "approved"
				? "checked_out"
				: "returned";
}

function approveLoan() {
	selectedLoanStatus = "approved";
	approvalOpen = false;
	competingRequestResolved = true;
}

function statusLabel(status: LoanStatus) {
	return status.replace("_", " ");
}
</script>

<svelte:head>
	<title>Mobile inventory workflow prototype</title>
</svelte:head>

<div
	class="mx-auto min-h-full max-w-md bg-background px-4 pb-32 pt-5 sm:border-x sm:px-5"
>
	<div class="mb-5 flex items-start gap-3">
		<a
			href="/dashboard/inventory"
			class="grid size-11 shrink-0 place-items-center rounded-lg border border-border bg-background text-foreground transition-colors hover:bg-muted focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
			aria-label="Back to inventory"
		>
			<ArrowLeft class="size-5" aria-hidden="true" />
		</a>
		<div>
			<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
				Prototype · ALE-276
			</p>
			<h1 class="font-heading text-2xl font-bold">Mobile item journeys</h1>
			<p class="mt-1 text-sm text-muted-foreground">
				Local sample state only. Test the flow, not the backend.
			</p>
		</div>
	</div>

	{#if variant === "member"}
		<section aria-labelledby="member-heading" class="space-y-4">
			<div
				class="rounded-2xl bg-primary p-5 text-primary-foreground shadow-[4px_4px_0_hsl(var(--secondary))]"
			>
				<p class="text-sm font-semibold text-primary-foreground/75">
					Member inventory
				</p>
				<h2 id="member-heading" class="mt-1 font-heading text-3xl">
					Find the right kit
				</h2>
				<p class="mt-2 text-sm leading-6 text-primary-foreground/85">
					Browse by equipment and its useful properties. Storage appears only
					when a request is approved.
				</p>
			</div>

			<label class="relative block">
				<span class="sr-only">Search items</span>
				<Search
					class="absolute left-4 top-1/2 size-5 -translate-y-1/2 text-muted-foreground"
				/>
				<Input
					class="h-12 pl-11 text-base"
					placeholder="Search swords, masks, size…"
				/>
			</label>
			<div class="flex gap-2 overflow-x-auto pb-1" aria-label="Item filters">
				<Button size="sm" class="min-h-11 shrink-0">Longsword</Button>
				<Button size="sm" variant="outline" class="min-h-11 shrink-0"
					>Medium flex</Button
				>
				<Button size="sm" variant="outline" class="min-h-11 shrink-0"
					>Available now</Button
				>
			</div>

			<article class="rounded-2xl border border-border bg-card p-4 shadow-sm">
				<div class="flex gap-3">
					<div
						class="grid size-12 shrink-0 place-items-center rounded-xl bg-secondary/20 text-primary"
					>
						<Package class="size-6" aria-hidden="true" />
					</div>
					<div class="min-w-0 flex-1">
						<div class="flex items-start justify-between gap-2">
							<h3 class="font-semibold">{item.label}</h3>
							<Badge variant="secondary" class="shrink-0">Available</Badge>
						</div>
						<p class="mt-1 text-sm text-muted-foreground">{item.category}</p>
						<p class="mt-3 text-sm">{item.properties.join(" · ")}</p>
						<p class="mt-3 font-mono text-xs text-muted-foreground">
							ID {item.slug}
						</p>
					</div>
				</div>
			</article>

			<div class="rounded-2xl border border-border bg-muted/40 p-4">
				<div class="flex items-center gap-2">
					<CalendarDays class="size-5 text-primary" aria-hidden="true" />
					<h3 class="font-semibold">Request this item</h3>
				</div>
				<div class="mt-3 grid grid-cols-2 gap-3">
					<label class="text-sm font-medium"
						>Collect
						<Input
							class="mt-1 h-11"
							value="4 Sep"
							aria-label="Collection date"
						/>
					</label>
					<label class="text-sm font-medium"
						>Return
						<Input class="mt-1 h-11" value="11 Sep" aria-label="Return date" />
					</label>
				</div>
				<label class="mt-3 block text-sm font-medium"
					>Note <span class="font-normal text-muted-foreground">(optional)</span
					>
					<Textarea class="mt-1" rows={2} placeholder="Training or event use" />
				</label>
				<Button
					class="mt-4 min-h-12 w-full text-base"
					onclick={() => (requestSubmitted = true)}
				>
					<ClipboardCheck class="size-5" aria-hidden="true" />
					{requestSubmitted ? "Request sent" : "Send request"}
				</Button>
				{#if requestSubmitted}
					<p
						class="mt-3 flex gap-2 text-sm text-emerald-700"
						aria-live="polite"
					>
						<Check class="mt-0.5 size-4 shrink-0" aria-hidden="true" />
						You will receive the approved dates and collection location if an operator
						approves it.
					</p>
				{/if}
			</div>
		</section>
	{:else if variant === "queue"}
		<section aria-labelledby="queue-heading" class="space-y-4">
			<div class="flex items-end justify-between gap-3">
				<div>
					<p class="text-sm font-semibold text-primary">Inventory operator</p>
					<h2 id="queue-heading" class="font-heading text-3xl">
						Today’s handovers
					</h2>
				</div>
				<Badge variant="destructive" class="mb-1">1 overdue</Badge>
			</div>
			<p class="text-sm leading-6 text-muted-foreground">
				A task queue makes the next physical action obvious, without exposing a
				member directory or an item table.
			</p>

			<div class="grid grid-cols-3 gap-2" aria-label="Queue summary">
				<div class="rounded-xl bg-secondary/20 p-3">
					<strong class="block text-xl">3</strong><span
						class="text-xs text-muted-foreground">Requests</span
					>
				</div>
				<div class="rounded-xl bg-primary/10 p-3">
					<strong class="block text-xl">2</strong><span
						class="text-xs text-muted-foreground">To hand over</span
					>
				</div>
				<div class="rounded-xl bg-destructive/10 p-3">
					<strong class="block text-xl">1</strong><span
						class="text-xs text-muted-foreground">To return</span
					>
				</div>
			</div>

			{#each activeLoans as loan, index (loan.member)}
				<article class="rounded-2xl border border-border bg-card p-4 shadow-sm">
					<div class="flex items-start justify-between gap-3">
						<div>
							<p class="text-xs font-bold tracking-wide text-primary uppercase">
								{statusLabel(loan.status)}
							</p>
							<h3 class="mt-1 font-semibold">{loan.member}</h3>
							<p class="mt-1 text-sm text-muted-foreground">{loan.item}</p>
						</div>
						<Clock3
							class="mt-1 size-5 shrink-0 text-muted-foreground"
							aria-hidden="true"
						/>
					</div>
					<div
						class="mt-4 flex items-center justify-between gap-3 border-t pt-3 text-sm"
					>
						<span>Due <strong>{loan.due}</strong></span>
						{#if index === 0}
							<Button
								onclick={() =>
									loan.status === "requested"
										? (approvalOpen = true)
										: advanceLoan()}
								class="min-h-11"
							>
								{loan.status === "requested"
									? "Approve"
									: loan.status === "approved"
										? "Record checkout"
										: "Record return"}
								<ArrowRight class="size-4" aria-hidden="true" />
							</Button>
						{:else}
							<Button variant="outline" class="min-h-11">Record return</Button>
						{/if}
					</div>
					{#if index === 0 && loan.status === "approved"}
						<p class="mt-3 flex gap-2 rounded-lg bg-muted p-3 text-sm">
							<MapPin class="size-4 shrink-0 text-primary" aria-hidden="true" />
							Collect from {item.container}. Confirm the labelled Item before
							checkout.
						</p>
					{/if}
				</article>
			{/each}
			{#if approvalOpen}
				<div
					class="rounded-2xl border-2 border-primary bg-primary/5 p-4"
					aria-live="polite"
				>
					<h3 class="font-semibold">Approve Aoife’s request</h3>
					<div class="mt-3 grid grid-cols-2 gap-3">
						<label class="text-sm font-medium"
							>Checkout<Input
								class="mt-1 h-11"
								value="4 Sep"
								aria-label="Approved checkout date"
							/></label
						>
						<label class="text-sm font-medium"
							>Due<Input
								class="mt-1 h-11"
								value="5 Sep"
								aria-label="Approved due date"
							/></label
						>
					</div>
					<label class="mt-3 block text-sm font-medium"
						>Approval note <span class="font-normal text-muted-foreground"
							>(optional)</span
						><Textarea
							class="mt-1"
							rows={2}
							placeholder="Bring gloves to collection"
						/></label
					>
					<div class="mt-4 flex gap-2">
						<Button
							variant="outline"
							class="min-h-11 flex-1"
							onclick={() => (approvalOpen = false)}>Cancel</Button
						>
						<Button class="min-h-11 flex-1" onclick={approveLoan}
							>Approve</Button
						>
					</div>
					<p class="mt-3 text-sm text-muted-foreground">
						Approval reserves the Item and rejects 1 competing request.
					</p>
				</div>
			{/if}
			{#if competingRequestResolved}
				<p class="rounded-xl bg-muted p-4 text-sm" aria-live="polite">
					The other pending request is now rejected with the standard system
					note.
				</p>
			{/if}
		</section>
	{:else}
		<section aria-labelledby="scan-heading" class="space-y-4">
			<div
				class="rounded-2xl bg-foreground p-5 text-background shadow-[4px_4px_0_hsl(var(--secondary))]"
			>
				<p class="text-sm font-semibold text-secondary">
					Inventory operator tools
				</p>
				<h2 id="scan-heading" class="mt-1 font-heading text-3xl">
					Identify the Item first
				</h2>
				<p class="mt-2 text-sm leading-6 text-background/80">
					Scanning opens an item’s existing detail and then exposes the safe
					next actions.
				</p>
			</div>

			<Button
				class="min-h-14 w-full text-base"
				size="lg"
				onclick={() => (scanOpen = !scanOpen)}
			>
				<QrCode class="size-6" aria-hidden="true" />
				{scanOpen ? "Close scanner" : "Scan Item QR label"}
			</Button>
			{#if scanOpen}
				<div
					class="grid aspect-square place-items-center rounded-2xl border-2 border-dashed border-primary bg-primary/5 p-6 text-center"
					aria-live="polite"
				>
					<div>
						<QrCode class="mx-auto size-20 text-primary" aria-hidden="true" />
						<p class="mt-4 font-semibold">Camera preview placeholder</p>
						<p class="mt-1 text-sm text-muted-foreground">
							Demo resolves {item.slug}; no camera permission requested.
						</p>
						<Button
							class="mt-4"
							variant="outline"
							onclick={() => {
								selectedItem = "Feder 01H4M8";
								scanOpen = false;
							}}>Use sample scan</Button
						>
					</div>
				</div>
			{/if}

			<article class="rounded-2xl border border-border bg-card p-4 shadow-sm">
				<div class="flex items-start gap-3">
					<div
						class="grid size-12 shrink-0 place-items-center rounded-xl bg-secondary/20 text-primary"
					>
						<Package class="size-6" aria-hidden="true" />
					</div>
					<div>
						<p class="font-semibold">{selectedItem}</p>
						<p class="mt-1 font-mono text-sm text-muted-foreground">
							{item.slug}
						</p>
						<Badge class="mt-3" variant="secondary">No active loan</Badge>
					</div>
				</div>
				<p class="mt-4 rounded-lg bg-muted p-3 text-sm">
					<MapPin
						class="mr-2 inline size-4 text-primary"
						aria-hidden="true"
					/>Home: {item.container}
				</p>
			</article>

			<div class="grid gap-3">
				<Button
					variant="outline"
					class="min-h-12 justify-start text-base"
					onclick={() => (moveRecorded = !moveRecorded)}
				>
					<ArrowRight class="size-5" aria-hidden="true" />
					{moveRecorded
						? "Move recorded to Cleaning bench"
						: "Move to another container"}
				</Button>
				<Button
					variant={maintenanceStarted ? "destructive" : "outline"}
					class="min-h-12 justify-start text-base"
					onclick={() => (maintenanceStarted = !maintenanceStarted)}
				>
					{#if maintenanceStarted}<ShieldAlert
							class="size-5"
							aria-hidden="true"
						/>{:else}<Wrench class="size-5" aria-hidden="true" />{/if}
					{maintenanceStarted ? "End maintenance" : "Start maintenance"}
				</Button>
			</div>
			{#if maintenanceStarted}
				<div class="rounded-2xl border border-border bg-muted/40 p-4">
					<label class="block text-sm font-medium"
						>Maintenance reason<Textarea
							bind:value={maintenanceReason}
							class="mt-1"
							rows={2}
							placeholder="Required before starting maintenance"
						/></label
					>
					<Button class="mt-3 min-h-11 w-full" disabled={!maintenanceReason}
						>Record maintenance start</Button
					>
					<label class="mt-4 block text-sm font-medium"
						>End note <span class="font-normal text-muted-foreground"
							>(optional)</span
						><Textarea
							bind:value={maintenanceNote}
							class="mt-1"
							rows={2}
							placeholder="Work completed"
						/></label
					>
					<Button
						variant="outline"
						class="mt-3 min-h-11 w-full"
						onclick={() => (maintenanceStarted = false)}
						>Record maintenance end</Button
					>
				</div>
			{/if}
			<p
				class="rounded-xl border border-secondary bg-secondary/10 p-4 text-sm leading-6"
			>
				<strong>Label decision:</strong> print the immutable slug and a QR code that
				resolves it. The visible label still gives a human a fallback when a camera,
				network, or label is unavailable.
			</p>
		</section>
	{/if}
</div>

<PrototypeVariantSwitcher {variants} current={variant} />
