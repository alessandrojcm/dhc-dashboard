<script lang="ts">
import { createWorkshop, updateWorkshop } from "./workshop-form.remote";
import { initForm } from "$lib/utils/init-form.svelte";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Textarea } from "$lib/components/ui/textarea";
import { Switch } from "$lib/components/ui/switch";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import * as Field from "$lib/components/ui/field";
import Calendar25 from "$lib/components/calendar-25.svelte";
import {
	BellRing,
	CalendarDays,
	Check,
	CircleCheckBig,
	Circle,
	Clock3,
	Euro,
	Earth,
	Mail,
	MapPin,
	Megaphone,
	ShieldCheck,
	Users,
} from "@lucide/svelte";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import {
	type CalendarDate,
	fromDate,
	getLocalTimeZone,
	toCalendarDate,
	toCalendarDateTime,
} from "@internationalized/date";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import dayjs from "dayjs";
import { untrack } from "svelte";

dayjs.extend(utc);
dayjs.extend(timezone);
dayjs.tz.setDefault(dayjs.tz.guess());

interface Props {
	mode: "create" | "edit";
	initialData?: Partial<{
		title: string;
		description: string;
		location: string;
		workshop_date: Date;
		workshop_end_date: Date;
		max_capacity: number;
		price_member: number;
		price_non_member: number;
		is_public: boolean;
		refund_deadline_days: number | null;
		announce_discord: boolean;
		announce_email: boolean;
	}>;
	onSuccess?: (result: { success: string; workshopId?: string }) => void;
	priceEditingDisabled?: boolean;
	workshopStatus?: string | null;
	workshopEditable?: boolean;
}

let {
	mode,
	initialData,
	onSuccess,
	priceEditingDisabled = false,
	workshopStatus,
	workshopEditable,
}: Props = $props();

// Select the appropriate form based on mode
const remoteForm = $derived(
	mode === "create" ? createWorkshop : updateWorkshop,
);
const baseInitialFormValue = $derived.by(() => ({
	title: initialData?.title ?? "",
	description: initialData?.description ?? "",
	location: initialData?.location ?? "",
	workshop_date: initialData?.workshop_date
		? dayjs(initialData.workshop_date).toISOString()
		: "",
	workshop_end_date: initialData?.workshop_end_date
		? dayjs(initialData.workshop_end_date).toISOString()
		: "",
	max_capacity: initialData?.max_capacity ?? 1,
	price_member: initialData?.price_member ?? 0,
	price_non_member: initialData?.price_non_member ?? 0,
	is_public: initialData?.is_public ?? false,
	refund_deadline_days: initialData?.refund_deadline_days ?? undefined,
}));
const createInitialFormValue = $derived({
	...baseInitialFormValue,
	announce_discord: initialData?.announce_discord ?? false,
	announce_email: initialData?.announce_email ?? false,
});
const updateInitialFormValue = $derived({ ...baseInitialFormValue });

// Current callers pass a static mode, so initialize only the selected
// module-scoped remote form and avoid clobbering another mounted form instance.
if (untrack(() => mode) === "create") {
	initForm(createWorkshop, () => createInitialFormValue);
} else {
	initForm(updateWorkshop, () => updateInitialFormValue);
}

// Derived values for reading form state
const workshopDate = $derived(remoteForm.fields.workshop_date.value());
const workshopEndDate = $derived(remoteForm.fields.workshop_end_date.value());
const isPublic = $derived(Boolean(remoteForm.fields.is_public.value()));
const title = $derived(String(remoteForm.fields.title.value() ?? ""));
const location = $derived(String(remoteForm.fields.location.value() ?? ""));
const maxCapacity = $derived(
	Number(remoteForm.fields.max_capacity.value() ?? 0),
);
const memberPrice = $derived(
	Number(remoteForm.fields.price_member.value() ?? 0),
);
const nonMemberPrice = $derived(
	Number(remoteForm.fields.price_non_member.value() ?? 0),
);
const refundDeadlineDays = $derived(
	remoteForm.fields.refund_deadline_days.value(),
);
const announceDiscord = $derived(
	mode === "create" && Boolean(createWorkshop.fields.announce_discord.value()),
);
const announceEmail = $derived(
	mode === "create" && Boolean(createWorkshop.fields.announce_email.value()),
);

const scheduleDate = $derived.by(() => {
	if (!workshopDate || !dayjs(workshopDate).isValid()) return "Date not set";
	return dayjs(workshopDate).format("ddd, D MMM YYYY");
});

const scheduleTime = $derived.by(() => {
	if (!workshopDate || !workshopEndDate) return "Time not set";
	const start = dayjs(workshopDate);
	const end = dayjs(workshopEndDate);
	if (!start.isValid() || !end.isValid()) return "Time not set";
	return `${start.format("HH:mm")}–${end.format("HH:mm")}`;
});

const setupChecklist = $derived([
	{
		label: "Workshop details",
		complete: Boolean(title.trim() && location.trim()),
	},
	{
		label: "Date and time",
		complete: Boolean(workshopDate && workshopEndDate),
	},
	{
		label: "Registration setup",
		complete: maxCapacity >= 1 && memberPrice >= 0,
	},
]);
const completedSetupSteps = $derived(
	setupChecklist.filter((item) => item.complete).length,
);

function formatPrice(value: number) {
	return new Intl.NumberFormat("en-IE", {
		style: "currency",
		currency: "EUR",
		minimumFractionDigits: value % 1 === 0 ? 0 : 2,
	}).format(value);
}

// Derived date values for Calendar25
const workshopDateValue = $derived.by(() => {
	if (!workshopDate) return undefined;
	const date = dayjs(workshopDate);
	if (!date.isValid()) return undefined;
	return toCalendarDate(fromDate(date.toDate(), getLocalTimeZone()));
});

const startTime = $derived.by(() => {
	if (!workshopDate) return "";
	const date = dayjs(workshopDate);
	return date.isValid() ? date.format("HH:mm") : "";
});

const endTime = $derived.by(() => {
	if (!workshopEndDate) return "";
	const date = dayjs(workshopEndDate);
	return date.isValid() ? date.format("HH:mm") : "";
});

// Date update helper - updates form fields
function updateWorkshopTime(time: string, field: "start" | "end") {
	const [hour, minute] = time.split(":").map(Number);
	if (field === "start") {
		const baseDate = workshopDate ? dayjs(workshopDate) : dayjs();
		remoteForm.fields.workshop_date.set(
			baseDate.hour(hour).minute(minute).toISOString(),
		);
		return;
	}

	if (field === "end") {
		const baseDate = workshopEndDate
			? dayjs(workshopEndDate)
			: workshopDate
				? dayjs(workshopDate)
				: dayjs();
		remoteForm.fields.workshop_end_date.set(
			baseDate.hour(hour).minute(minute).toISOString(),
		);
		return;
	}
}

function updateWorkshopDate(date: CalendarDate | undefined) {
	if (!date) return;
	const startDateDayjs = workshopDate ? dayjs(workshopDate) : null;
	const startTimeVal = startDateDayjs?.isValid()
		? {
				hour: startDateDayjs.hour(),
				minute: startDateDayjs.minute(),
			}
		: { hour: 10, minute: 0 };

	const endDateDayjs = workshopEndDate ? dayjs(workshopEndDate) : null;
	const endTimeVal = endDateDayjs?.isValid()
		? { hour: endDateDayjs.hour(), minute: endDateDayjs.minute() }
		: { hour: 12, minute: 0 };

	remoteForm.fields.workshop_date.set(
		toCalendarDateTime(date)
			.set(startTimeVal)
			.toDate(getLocalTimeZone())
			.toISOString(),
	);

	remoteForm.fields.workshop_end_date.set(
		toCalendarDateTime(date)
			.set(endTimeVal)
			.toDate(getLocalTimeZone())
			.toISOString(),
	);
}

// Edit permissions
const isWorkshopEditable = $derived.by(() => {
	if (mode === "create") return true;
	if (workshopStatus === "published") return false;
	if (workshopEditable !== undefined) return workshopEditable;
	return workshopStatus === "planned";
});

const canEditPricing = $derived.by(() => {
	if (mode === "create") return true;
	if (workshopStatus === "planned") return true;
	return !priceEditingDisabled;
});

// Handle form result
$effect(() => {
	const result = remoteForm.result;
	if (result?.success) {
		window?.scrollTo({ top: 0, behavior: "smooth" });
		if (onSuccess) {
			onSuccess(result);
		}
	}
});

// Success and error messages from form result
const successMessage = $derived(remoteForm.result?.success);
</script>

<div class="space-y-5">
	{#if successMessage}
		<div role="status" aria-live="polite">
			<Alert variant="default" class="border-green-200 bg-green-50">
				<CircleCheckBig class="h-4 w-4 text-green-700" />
				<AlertDescription class="text-green-900">
					{successMessage}
				</AlertDescription>
			</Alert>
		</div>
	{/if}

	{#if !isWorkshopEditable}
		<Alert variant="default" class="border-yellow-200 bg-yellow-50">
			<AlertDescription class="text-yellow-800">
				{#if workshopStatus === "published"}
					This workshop cannot be edited because it has been published.
				{:else if workshopStatus === "finished"}
					This workshop cannot be edited because it has been finished.
				{:else if workshopStatus === "cancelled"}
					This workshop cannot be edited because it has been cancelled.
				{:else}
					This workshop cannot be edited because it has been published,
					finished, or cancelled.
				{/if}
			</AlertDescription>
		</Alert>
	{/if}

	<form
		{...remoteForm}
		class="grid items-start gap-5 lg:grid-cols-[minmax(0,1fr)_21rem] xl:grid-cols-[minmax(0,1fr)_23rem]"
	>
		<div class="space-y-5 lg:col-start-1">
			<!-- Basic Information Section -->
			<section
				class="space-y-6 rounded-2xl border border-border/80 bg-card p-5 shadow-[4px_4px_0_rgb(18_24_39_/_8%)] sm:p-6 lg:col-start-1"
				aria-labelledby="workshop-details-heading"
			>
				<div class="flex items-start gap-4">
					<div
						class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary text-sm font-bold text-primary-foreground"
					>
						1
					</div>
					<div>
						<h2
							id="workshop-details-heading"
							class="text-xl font-semibold tracking-tight"
						>
							Workshop details
						</h2>
						<p class="mt-1 text-sm leading-6 text-muted-foreground">
							Help members understand what the session is and where it takes
							place.
						</p>
					</div>
				</div>

				<div class="grid grid-cols-1 gap-6 md:grid-cols-2">
					<Field.Field>
						{@const fieldProps = remoteForm.fields.title.as("text")}
						<Field.Label for={fieldProps.name}>Workshop title</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							placeholder="e.g. Introduction to longsword"
							class="h-11"
							disabled={!isWorkshopEditable}
						/>
						{#each remoteForm.fields.title.issues() as issue, index (`${issue.message}-${index}`)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = remoteForm.fields.location.as("text")}
						<Field.Label for={fieldProps.name}>Location</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							placeholder="e.g. Main training hall"
							class="h-11"
							disabled={!isWorkshopEditable}
						/>
						{#each remoteForm.fields.location.issues() as issue, index (`${issue.message}-${index}`)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</div>

				<Field.Field>
					{@const fieldProps = remoteForm.fields.description.as("text")}
					<Field.Label for={fieldProps.name}>Description</Field.Label>
					<Textarea
						{...fieldProps}
						id={fieldProps.name}
						placeholder="What will attendees learn, and what should they bring?"
						rows={5}
						class="min-h-32 resize-y"
						disabled={!isWorkshopEditable}
					/>
					<p class="text-sm leading-5 text-muted-foreground">
						Optional, but useful for setting expectations before registration.
					</p>
					{#each remoteForm.fields.description.issues() as issue, index (`${issue.message}-${index}`)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</section>

			<!-- Date & Time Section -->
			<section
				class="space-y-6 rounded-2xl border border-border/80 bg-card p-5 shadow-[4px_4px_0_rgb(18_24_39_/_8%)] sm:p-6 lg:col-start-1"
				aria-labelledby="schedule-heading"
			>
				<div class="flex items-start gap-4">
					<div
						class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-secondary text-sm font-bold text-secondary-foreground"
					>
						2
					</div>
					<div>
						<h2
							id="schedule-heading"
							class="text-xl font-semibold tracking-tight"
						>
							Date and time
						</h2>
						<p class="mt-1 text-sm leading-6 text-muted-foreground">
							Set the workshop date and the expected start and finish times.
						</p>
					</div>
				</div>

				<Field.Field>
					<Field.Label>Workshop date and time</Field.Label>
					<div
						class="rounded-xl border border-border/70 bg-muted/25 p-4 sm:p-5"
					>
						<Calendar25
							id="workshop"
							date={workshopDateValue}
							{startTime}
							{endTime}
							onDateChange={updateWorkshopDate}
							onStartTimeChange={(time) => updateWorkshopTime(time, "start")}
							onEndTimeChange={(time) => updateWorkshopTime(time, "end")}
							disabled={!isWorkshopEditable}
						/>
					</div>
					<input name="workshop_date" type="hidden" value={workshopDate} />
					<input
						name="workshop_end_date"
						type="hidden"
						value={workshopEndDate}
					/>
					{#each remoteForm.fields.workshop_date.issues() as issue, index (`${issue.message}-${index}`)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
					{#each remoteForm.fields.workshop_end_date.issues() as issue, index (`${issue.message}-${index}`)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</section>

			<!-- Workshop Details Section -->
			<section
				class="space-y-6 rounded-2xl border border-border/80 bg-card p-5 shadow-[4px_4px_0_rgb(18_24_39_/_8%)] sm:p-6 lg:col-start-1"
				aria-labelledby="capacity-heading"
			>
				<div class="flex items-start gap-4">
					<div
						class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-accent text-sm font-bold text-accent-foreground"
					>
						3
					</div>
					<div>
						<h2
							id="capacity-heading"
							class="text-xl font-semibold tracking-tight"
						>
							Capacity and refunds
						</h2>
						<p class="mt-1 text-sm leading-6 text-muted-foreground">
							Control available places and when attendee refunds close.
						</p>
					</div>
				</div>

				<div class="grid grid-cols-1 gap-6 md:grid-cols-2">
					<Field.Field>
						{@const fieldProps = remoteForm.fields.max_capacity.as("number")}
						<Field.Label for={fieldProps.name}>Available places</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							min="1"
							placeholder="12"
							class="h-11"
							disabled={!isWorkshopEditable}
						/>
						<p class="text-sm leading-5 text-muted-foreground">
							Registration closes when all places are taken.
						</p>
						{#each remoteForm.fields.max_capacity.issues() as issue, index (`${issue.message}-${index}`)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps =
							remoteForm.fields.refund_deadline_days.as("number")}
						<Field.Label for={fieldProps.name}>Refund cutoff</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							min="0"
							placeholder="3"
							class="h-11"
							disabled={!isWorkshopEditable}
						/>
						<p class="text-sm leading-5 text-muted-foreground">
							Number of days before the workshop. Use 0 for no cutoff.
						</p>
						{#each remoteForm.fields.refund_deadline_days.issues() as issue, index (`${issue.message}-${index}`)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</div>
			</section>

			<!-- Communication Settings Section (Create mode only) -->
			{#if mode === "create"}
				<section
					class="space-y-6 rounded-2xl border border-border/80 bg-card p-5 shadow-[4px_4px_0_rgb(18_24_39_/_8%)] sm:p-6 lg:col-start-1"
					aria-labelledby="communication-heading"
				>
					<div class="flex items-start gap-4">
						<div
							class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-sm font-bold text-primary"
						>
							4
						</div>
						<div>
							<h2
								id="communication-heading"
								class="text-xl font-semibold tracking-tight"
							>
								Announcements
							</h2>
							<p class="mt-1 text-sm leading-6 text-muted-foreground">
								Optional. Choose where future workshop updates are sent.
							</p>
						</div>
					</div>

					<div class="grid gap-4 md:grid-cols-2">
						<div class="rounded-xl border border-border bg-muted/20 p-4">
							<div class="flex items-start justify-between gap-3">
								<label
									for="announce_discord"
									class="flex min-h-11 flex-1 cursor-pointer items-start gap-3"
								>
									<span
										class="flex size-10 shrink-0 items-center justify-center rounded-lg bg-background text-primary shadow-xs"
									>
										<Megaphone aria-hidden="true" class="size-5" />
									</span>
									<span>
										<span class="block font-semibold">Discord</span>
										<span
											class="mt-1 block text-sm leading-5 text-muted-foreground"
										>
											Post updates to the club server.
										</span>
									</span>
								</label>
								<Switch
									id="announce_discord"
									checked={announceDiscord}
									onCheckedChange={(v) =>
										createWorkshop.fields.announce_discord.set(v)}
								/>
							</div>
							<input
								type="hidden"
								name="announce_discord"
								value={String(announceDiscord)}
							/>
						</div>

						<div class="rounded-xl border border-border bg-muted/20 p-4">
							<div class="flex items-start justify-between gap-3">
								<label
									for="announce_email"
									class="flex min-h-11 flex-1 cursor-pointer items-start gap-3"
								>
									<span
										class="flex size-10 shrink-0 items-center justify-center rounded-lg bg-background text-primary shadow-xs"
									>
										<Mail aria-hidden="true" class="size-5" />
									</span>
									<span>
										<span class="block font-semibold">Email</span>
										<span
											class="mt-1 block text-sm leading-5 text-muted-foreground"
										>
											Email all active members.
										</span>
									</span>
								</label>
								<Switch
									id="announce_email"
									checked={announceEmail}
									onCheckedChange={(v) =>
										createWorkshop.fields.announce_email.set(v)}
								/>
							</div>
							<input
								type="hidden"
								name="announce_email"
								value={String(announceEmail)}
							/>
						</div>
					</div>
				</section>
			{/if}

			<!-- Pricing & Access Section -->
			<section
				class="space-y-6 rounded-2xl border border-border/80 bg-card p-5 shadow-[4px_4px_0_rgb(18_24_39_/_8%)] sm:p-6 lg:col-start-1"
				aria-labelledby="pricing-heading"
			>
				<div class="flex items-start gap-4">
					<div
						class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-secondary/30 text-sm font-bold text-foreground"
					>
						{mode === "create" ? 5 : 4}
					</div>
					<div>
						<h2
							id="pricing-heading"
							class="text-xl font-semibold tracking-tight"
						>
							Registration and pricing
						</h2>
						<p class="mt-1 text-sm leading-6 text-muted-foreground">
							Choose who can register and what each attendee type pays.
						</p>
					</div>
				</div>

				{#if !canEditPricing}
					<Alert variant="default" class="border-orange-200 bg-orange-50">
						<AlertDescription class="text-orange-800">
							Pricing cannot be changed because there are already registered
							attendees.
						</AlertDescription>
					</Alert>
				{/if}

				<div
					class={`rounded-xl border p-4 transition-colors duration-200 ${
						isPublic
							? "border-primary/40 bg-primary/5"
							: "border-border bg-muted/20"
					}`}
				>
					<div class="flex items-start justify-between gap-4">
						<label
							for="is_public"
							class="flex min-h-11 flex-1 cursor-pointer items-start gap-3"
						>
							<span
								class="flex size-10 shrink-0 items-center justify-center rounded-lg bg-background text-primary shadow-xs"
							>
								{#if isPublic}
									<Earth aria-hidden="true" class="size-5" />
								{:else}
									<ShieldCheck aria-hidden="true" class="size-5" />
								{/if}
							</span>
							<span>
								<span class="block font-semibold">
									{isPublic ? "Open to everyone" : "Members only"}
								</span>
								<span
									class="mt-1 block text-sm leading-5 text-muted-foreground"
								>
									{isPublic
										? "Non-members can view and register for this workshop."
										: "Only signed-in club members can register."}
								</span>
							</span>
						</label>
						<Switch
							id="is_public"
							checked={isPublic}
							onCheckedChange={(v) => remoteForm.fields.is_public.set(v)}
							disabled={!isWorkshopEditable}
						/>
					</div>
					<input type="hidden" name="is_public" value={String(isPublic)} />
					{#each remoteForm.fields.is_public.issues() as issue, index (`${issue.message}-${index}`)}
						<Field.Error class="mt-3">{issue.message}</Field.Error>
					{/each}
				</div>

				<div class="grid grid-cols-1 gap-6 md:grid-cols-2">
					<Field.Field>
						{@const fieldProps = remoteForm.fields.price_member.as("number")}
						<Field.Label for={fieldProps.name}>Member price</Field.Label>
						<div class="relative">
							<span
								class="absolute left-3 top-1/2 -translate-y-1/2 text-sm text-muted-foreground"
							>
								€
							</span>
							<Input
								{...fieldProps}
								id={fieldProps.name}
								min="0"
								step="0.01"
								class="h-11 pl-8"
								placeholder="0.00"
								disabled={!canEditPricing}
							/>
						</div>
						<p class="text-sm leading-5 text-muted-foreground">
							Use €0 for a free workshop.
						</p>
						{#each remoteForm.fields.price_member.issues() as issue, index (`${issue.message}-${index}`)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					{#if isPublic}
						{@const fieldProps =
							remoteForm.fields.price_non_member.as("number")}
						<Field.Field>
							<Field.Label for={fieldProps.name}>Non-member price</Field.Label>
							<div class="relative">
								<span
									class="absolute left-3 top-1/2 -translate-y-1/2 text-sm text-muted-foreground"
								>
									€
								</span>
								<Input
									{...fieldProps}
									id={fieldProps.name}
									min="0"
									step="0.01"
									class="h-11 pl-8"
									placeholder="0.00"
									disabled={!canEditPricing}
								/>
							</div>
							<p class="text-sm leading-5 text-muted-foreground">
								Shown only to non-member registrants.
							</p>
							{#each remoteForm.fields.price_non_member.issues() as issue, index (`${issue.message}-${index}`)}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>
					{:else}
						<div
							class="flex min-h-24 items-center gap-3 rounded-xl border border-dashed border-border bg-muted/20 p-4 text-muted-foreground"
						>
							<ShieldCheck aria-hidden="true" class="size-5 shrink-0" />
							<div>
								<p class="text-sm font-semibold text-foreground">
									Members-only access
								</p>
								<p class="mt-1 text-sm leading-5">
									Turn on public access to set a non-member price.
								</p>
							</div>
						</div>
					{/if}
				</div>
			</section>
		</div>

		<!-- Submit Section -->
		<aside class="space-y-4 lg:sticky lg:top-6 lg:col-start-2 lg:row-start-1">
			<div
				class="overflow-hidden rounded-2xl border border-primary/25 bg-card shadow-[5px_5px_0_rgb(31_79_133_/_14%)]"
			>
				<div
					class="border-b border-primary/20 bg-primary px-5 py-4 text-primary-foreground"
				>
					<div class="flex items-center gap-2 text-sm font-semibold">
						<BellRing aria-hidden="true" class="size-4" />
						Workshop preview
					</div>
					<p class="mt-2 text-lg font-semibold leading-6">
						{title.trim() || "Untitled workshop"}
					</p>
				</div>

				<div class="space-y-4 p-5">
					<div class="flex gap-3">
						<CalendarDays
							aria-hidden="true"
							class="mt-0.5 size-4 shrink-0 text-primary"
						/>
						<div>
							<p class="text-sm font-semibold">{scheduleDate}</p>
							<p
								class="mt-0.5 flex items-center gap-1.5 text-sm text-muted-foreground"
							>
								<Clock3 aria-hidden="true" class="size-3.5" />
								{scheduleTime}
							</p>
						</div>
					</div>

					<div class="flex gap-3">
						<MapPin
							aria-hidden="true"
							class="mt-0.5 size-4 shrink-0 text-primary"
						/>
						<p class="text-sm leading-5">
							{location.trim() || "Location not set"}
						</p>
					</div>

					<div class="grid grid-cols-2 gap-3">
						<div class="rounded-xl bg-muted/35 p-3">
							<Users aria-hidden="true" class="size-4 text-primary" />
							<p class="mt-2 text-xs font-medium text-muted-foreground">
								Places
							</p>
							<p class="text-sm font-semibold">
								{maxCapacity >= 1 ? maxCapacity : "Not set"}
							</p>
						</div>
						<div class="rounded-xl bg-muted/35 p-3">
							<Euro aria-hidden="true" class="size-4 text-primary" />
							<p class="mt-2 text-xs font-medium text-muted-foreground">
								Members
							</p>
							<p class="text-sm font-semibold">{formatPrice(memberPrice)}</p>
						</div>
					</div>

					<div class="rounded-xl border border-border/80 p-3">
						<div class="flex items-center gap-2">
							{#if isPublic}
								<Earth aria-hidden="true" class="size-4 text-primary" />
								<span class="text-sm font-semibold">Public registration</span>
							{:else}
								<ShieldCheck aria-hidden="true" class="size-4 text-primary" />
								<span class="text-sm font-semibold">Members only</span>
							{/if}
						</div>
						{#if isPublic}
							<p class="mt-1 pl-6 text-xs text-muted-foreground">
								Non-members pay {formatPrice(nonMemberPrice)}
							</p>
						{/if}
					</div>

					{#if refundDeadlineDays !== undefined}
						<p class="text-xs leading-5 text-muted-foreground">
							Refunds close {refundDeadlineDays}
							{refundDeadlineDays === 1 ? "day" : "days"} before the workshop.
						</p>
					{/if}
				</div>
			</div>

			<div class="rounded-2xl border border-border/80 bg-card p-5">
				<div class="flex items-baseline justify-between gap-3">
					<h2 class="text-sm font-semibold">
						Ready to {mode === "create" ? "create" : "update"}
					</h2>
					<span class="text-xs font-semibold text-primary">
						{completedSetupSteps}/{setupChecklist.length}
					</span>
				</div>
				<ul class="mt-3 space-y-2.5">
					{#each setupChecklist as item (item.label)}
						<li class="flex items-center gap-2 text-sm">
							{#if item.complete}
								<Check aria-hidden="true" class="size-4 text-green-700" />
							{:else}
								<Circle
									aria-hidden="true"
									class="size-4 text-muted-foreground"
								/>
							{/if}
							<span class:text-muted-foreground={!item.complete}
								>{item.label}</span
							>
						</li>
					{/each}
				</ul>
			</div>

			<Button
				type="submit"
				disabled={!!remoteForm.pending || !isWorkshopEditable}
				class="h-12 w-full text-base"
			>
				{#if remoteForm.pending}
					<LoaderCircle class="mr-2 h-5 w-5" />
					{mode === "create" ? "Creating" : "Updating"} Workshop...
				{:else}
					{mode === "create" ? "Create" : "Update"} Workshop
				{/if}
			</Button>
			<p class="px-3 text-center text-xs leading-5 text-muted-foreground">
				{mode === "create"
					? "Creating saves this as a planned workshop. You can review it before publishing."
					: "Your changes take effect as soon as the workshop is updated."}
			</p>
		</aside>
	</form>
</div>
