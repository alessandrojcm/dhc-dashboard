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
    import { CheckCircle } from "lucide-svelte";
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
    const remoteForm = $derived(mode === "create" ? createWorkshop : updateWorkshop);
    const initialFormValue = $derived.by(() => {
        if (mode === "create") {
            return {
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
                refund_deadline_days:
                    initialData?.refund_deadline_days ?? undefined,
                announce_discord: initialData?.announce_discord ?? false,
                announce_email: initialData?.announce_email ?? false,
            };
        }
        return {
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
            refund_deadline_days:
                initialData?.refund_deadline_days ?? undefined,
        };
    });

    // Initialize the appropriate form based on mode
    if (mode === "create") {
        initForm(createWorkshop, () => initialFormValue);
    } else {
        initForm(updateWorkshop, () => initialFormValue);
    }

    // Derived values for reading form state
    const workshopDate = $derived(
        remoteForm.fields.workshop_date.value(),
    );
    const workshopEndDate = $derived(
        remoteForm.fields.workshop_end_date.value(),
    );
    const isPublic = $derived(Boolean(remoteForm.fields.is_public.value()));

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
    function updateWorkshopDates(
        date?: CalendarDate | string,
        op: "start" | "end" | "date" = "date",
    ) {
        if (!date) return;

        if (typeof date === "string" && op === "start") {
            const [hour, minute] = date.split(":").map(Number);
            const baseDate = workshopDate ? dayjs(workshopDate) : dayjs();
            remoteForm.fields.workshop_date.set(
                baseDate.hour(hour).minute(minute).toISOString(),
            );
            return;
        }

        if (typeof date === "string" && op === "end") {
            const [hour, minute] = date.split(":").map(Number);
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

        // Handle date change (CalendarDate) - preserve existing times or use defaults
        if (typeof date !== "string") {
            const startDateDayjs = workshopDate ? dayjs(workshopDate) : null;
            const startTimeVal = startDateDayjs?.isValid()
                ? {
                      hour: startDateDayjs.hour(),
                      minute: startDateDayjs.minute(),
                  }
                : { hour: 10, minute: 0 };

            const endDateDayjs = workshopEndDate
                ? dayjs(workshopEndDate)
                : null;
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
    const errorMessage = $derived.by(() => {
        // Check for error in result
        if (remoteForm.result && "error" in remoteForm.result) {
            return (remoteForm.result as { error: string }).error;
        }
        // Check for issues array in result
        if (remoteForm.result && "issues" in remoteForm.result) {
            const issues = (
                remoteForm.result as { issues: Array<{ message: string }> }
            ).issues;
            if (issues?.length > 0) return issues[0]?.message;
        }
        return null;
    });
</script>

<div class="space-y-8">
    {#if successMessage}
        <Alert variant="default" class="border-green-200 bg-green-50">
            <CheckCircle class="h-4 w-4 text-green-600" />
            <AlertDescription class="text-green-800"
                >{successMessage}</AlertDescription
            >
        </Alert>
    {/if}

    {#if errorMessage}
        <Alert variant="destructive">
            <AlertDescription>{errorMessage}</AlertDescription>
        </Alert>
    {/if}

    {#if !isWorkshopEditable}
        <Alert variant="default" class="border-yellow-200 bg-yellow-50">
            <AlertDescription class="text-yellow-800">
                {#if workshopStatus === "published"}
                    This workshop cannot be edited because it has been
                    published.
                {:else if workshopStatus === "finished"}
                    This workshop cannot be edited because it has been finished.
                {:else if workshopStatus === "cancelled"}
                    This workshop cannot be edited because it has been
                    cancelled.
                {:else}
                    This workshop cannot be edited because it has been
                    published, finished, or cancelled.
                {/if}
            </AlertDescription>
        </Alert>
    {/if}

    <form
        {...remoteForm}
        class="space-y-8 rounded-lg border bg-white p-6 shadow-sm"
    >
        <!-- Basic Information Section -->
        <div class="space-y-6">
            <h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
                Basic Information
            </h2>

            <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
                <Field.Field>
                    {@const fieldProps = remoteForm.fields.title.as("text")}
                    <Field.Label for={fieldProps.name}>Title</Field.Label>
                    <Input
                        {...fieldProps}
                        id={fieldProps.name}
                        placeholder="Enter workshop title"
                        disabled={!isWorkshopEditable}
                    />
                    {#each remoteForm.fields.title.issues() as issue}
                        <Field.Error>{issue.message}</Field.Error>
                    {/each}
                </Field.Field>

                <Field.Field>
                    {@const fieldProps = remoteForm.fields.location.as("text")}
                    <Field.Label for={fieldProps.name}>Location</Field.Label>
                    <Input
                        {...fieldProps}
                        id={fieldProps.name}
                        placeholder="Enter workshop location"
                        disabled={!isWorkshopEditable}
                    />
                    {#each remoteForm.fields.location.issues() as issue}
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
                    placeholder="Enter workshop description"
                    rows={4}
                    disabled={!isWorkshopEditable}
                />
                {#each remoteForm.fields.description.issues() as issue}
                    <Field.Error>{issue.message}</Field.Error>
                {/each}
            </Field.Field>
        </div>

        <!-- Date & Time Section -->
        <div class="space-y-6">
            <h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
                Date & Time
            </h2>

            <Field.Field>
                <Field.Label>Workshop Date & Time</Field.Label>
                <div class="rounded-lg bg-gray-50 p-4">
                    <Calendar25
                        id="workshop"
                        date={workshopDateValue}
                        {startTime}
                        {endTime}
                        onDateChange={(d) => updateWorkshopDates(d, "date")}
                        onStartTimeChange={(d) =>
                            updateWorkshopDates(d, "start")}
                        onEndTimeChange={(d) => updateWorkshopDates(d, "end")}
                        disabled={!isWorkshopEditable}
                    />
                </div>
                <input
                    name="workshop_date"
                    type="hidden"
                    value={workshopDate}
                />
                <input
                    name="workshop_end_date"
                    type="hidden"
                    value={workshopEndDate}
                />
                {#each remoteForm.fields.workshop_date.issues() as issue}
                    <Field.Error>{issue.message}</Field.Error>
                {/each}
                {#each remoteForm.fields.workshop_end_date.issues() as issue}
                    <Field.Error>{issue.message}</Field.Error>
                {/each}
            </Field.Field>
        </div>

        <!-- Workshop Details Section -->
        <div class="space-y-6">
            <h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
                Workshop Details
            </h2>

            <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
                <Field.Field>
                    {@const fieldProps =
                        remoteForm.fields.max_capacity.as("number")}
                    <Field.Label for={fieldProps.name}
                        >Maximum Capacity</Field.Label
                    >
                    <Input
                        {...fieldProps}
                        id={fieldProps.name}
                        min="1"
                        placeholder="Enter maximum capacity"
                        disabled={!isWorkshopEditable}
                    />
                    {#each remoteForm.fields.max_capacity.issues() as issue}
                        <Field.Error>{issue.message}</Field.Error>
                    {/each}
                </Field.Field>

                <Field.Field>
                    {@const fieldProps =
                        remoteForm.fields.refund_deadline_days.as("number")}
                    <Field.Label for={fieldProps.name}
                        >Refund Deadline (days)</Field.Label
                    >
                    <Input
                        {...fieldProps}
                        id={fieldProps.name}
                        min="0"
                        placeholder="3"
                        disabled={!isWorkshopEditable}
                    />
                    <p class="mt-1 text-sm text-muted-foreground">
                        Days before workshop when refunds are no longer
                        available
                    </p>
                    {#each remoteForm.fields.refund_deadline_days.issues() as issue}
                        <Field.Error>{issue.message}</Field.Error>
                    {/each}
                </Field.Field>
            </div>
        </div>

        <!-- Communication Settings Section (Create mode only) -->
        {#if mode === "create"}
            <div class="space-y-6">
                <h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
                    Communication Settings
                </h2>

                <div class="rounded-lg border border-blue-200 bg-blue-50 p-4">
                    <p class="mb-4 text-sm text-blue-700">
                        All workshop status changes will be announced through
                        selected channels
                    </p>

                    <div class="space-y-4">
                        <div class="flex items-center space-x-3">
                            <Switch
                                id="announce_discord"
                                checked={Boolean(createWorkshop.fields.announce_discord.value())}
                                onCheckedChange={(v) =>
                                    createWorkshop.fields.announce_discord.set(
                                        v,
                                    )}
                            />
                            <input type="hidden" name="announce_discord" value={String(Boolean(createWorkshop.fields.announce_discord.value()))} />
                            <div>
                                <label
                                    for="announce_discord"
                                    class="text-base font-medium"
                                >
                                    Announce in Discord
                                </label>
                                <p class="text-sm text-blue-700">
                                    Send workshop announcements to the Discord
                                    server
                                </p>
                            </div>
                        </div>

                        <div class="flex items-center space-x-3">
                            <Switch
                                id="announce_email"
                                checked={Boolean(createWorkshop.fields.announce_email.value())}
                                onCheckedChange={(v) =>
                                    createWorkshop.fields.announce_email.set(v)}
                            />
                            <input type="hidden" name="announce_email" value={String(Boolean(createWorkshop.fields.announce_email.value()))} />
                            <div>
                                <label
                                    for="announce_email"
                                    class="text-base font-medium"
                                >
                                    Announce via Email
                                </label>
                                <p class="text-sm text-blue-700">
                                    Send workshop announcements via email to all
                                    active members
                                </p>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        {/if}

        <!-- Pricing & Access Section -->
        <div class="space-y-6">
            <h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
                Pricing & Access
            </h2>

            {#if !canEditPricing}
                <Alert variant="default" class="border-orange-200 bg-orange-50">
                    <AlertDescription class="text-orange-800">
                        Pricing cannot be changed because there are already
                        registered attendees.
                    </AlertDescription>
                </Alert>
            {/if}

            <div
                class="flex items-center space-x-3 rounded-lg border border-blue-200 bg-blue-50 p-4"
            >
                <Switch
                    id="is_public"
                    checked={isPublic}
                    onCheckedChange={(v) => remoteForm.fields.is_public.set(v)}
                    disabled={!isWorkshopEditable}
                />
                <input type="hidden" name="is_public" value={String(isPublic)} />
                <div>
                    <label for="is_public" class="text-base font-medium">
                        Public Workshop
                    </label>
                    <p class="mt-1 text-sm text-blue-700">
                        Enable this to allow non-members to register for the
                        workshop
                    </p>
                </div>
                {#each remoteForm.fields.is_public.issues() as issue}
                    <Field.Error>{issue.message}</Field.Error>
                {/each}
            </div>

            <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
                <Field.Field>
                    {@const fieldProps =
                        remoteForm.fields.price_member.as("number")}
                    <Field.Label for={fieldProps.name}>Member Price</Field.Label
                    >
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
                            class="pl-8"
                            placeholder="10.00"
                            disabled={!canEditPricing}
                        />
                    </div>
                </Field.Field>

                {#if isPublic}
                    {@const fieldProps =
                        remoteForm.fields.price_non_member.as("number")}
                    <Field.Field>
                        <Field.Label for={fieldProps.name}
                            >Non-Member Price</Field.Label
                        >
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
                                class="pl-8"
                                placeholder="20.00"
                                disabled={!canEditPricing}
                            />
                        </div>
                    </Field.Field>
                {:else}
                    <div
                        class="flex h-20 items-center justify-center rounded-lg border border-dashed border-gray-300 bg-gray-50 text-sm text-muted-foreground"
                    >
                        <div class="text-center">
                            <p class="font-medium">Non-Member Pricing</p>
                            <p class="text-xs">
                                Available for public workshops only
                            </p>
                        </div>
                    </div>
                {/if}
            </div>
        </div>

        <!-- Submit Section -->
        <div class="border-t pt-6">
            <Button
                type="submit"
                disabled={!!remoteForm.pending || !isWorkshopEditable}
                class="h-12 w-full text-lg"
            >
                {#if remoteForm.pending}
                    <LoaderCircle class="mr-2 h-5 w-5" />
                    {mode === "create" ? "Creating" : "Updating"} Workshop...
                {:else}
                    {mode === "create" ? "Create" : "Update"} Workshop
                {/if}
            </Button>
        </div>
    </form>
</div>
