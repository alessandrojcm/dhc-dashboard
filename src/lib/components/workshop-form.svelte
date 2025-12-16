<script lang="ts">
    import {superForm} from 'sveltekit-superforms';
    import {valibotClient} from 'sveltekit-superforms/adapters';

    import {Button} from '$lib/components/ui/button';
    import {Input} from '$lib/components/ui/input';
    import {Textarea} from '$lib/components/ui/textarea';
    import {Switch} from '$lib/components/ui/switch';
    import {Alert, AlertDescription} from '$lib/components/ui/alert';
    import * as Form from '$lib/components/ui/form';
    import Calendar25 from '$lib/components/calendar-25.svelte';
    import {CheckCircle} from 'lucide-svelte';
    import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
    import {
        type CalendarDate,
        fromDate,
        getLocalTimeZone,
        toCalendarDate,
        toCalendarDateTime
    } from '@internationalized/date';
    import utc from 'dayjs/plugin/utc';
    import timezone from 'dayjs/plugin/timezone';
    import dayjs from 'dayjs';
    import {CreateWorkshopSchema, UpdateWorkshopSchema} from '$lib/server/services/workshops';

    dayjs.extend(utc);
    dayjs.extend(timezone);
    dayjs.tz.setDefault(dayjs.tz.guess());

    interface Props {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        data: any;
        mode: 'create' | 'edit';
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        onSuccess?: (form: any) => void;
        priceEditingDisabled?: boolean;
        workshopStatus?: string | null;
        workshopEditable?: boolean;
    }

    const {
        data,
        mode,
        onSuccess,
        priceEditingDisabled = false,
        workshopStatus,
        workshopEditable
    }: Props = $props();

    const schema = mode === 'create' ? CreateWorkshopSchema : UpdateWorkshopSchema;

    const form = superForm(data.form, {
        validators: valibotClient(schema),
        validationMethod: 'onblur',
        onSubmit: ({formData}) => {
            formData.set('workshop_date', dayjs(formData.get('workshop_date') as string).toISOString());
            formData.set(
                'workshop_end_date',
                dayjs(formData.get('workshop_end_date') as string).toISOString()
            );
        },
        onUpdated: ({form}) => {
            if (form.message?.success) {
                window?.scrollTo({top: 0, behavior: 'smooth'});
                if (onSuccess) {
                    reset({
                        keepMessage: false
                    });
                    onSuccess(form);
                }
            }
        }
    });

    const {form: formData, enhance, submitting, message, reset} = form;

    const workshopDateValue = $derived.by(() => {
        const date = dayjs($formData.workshop_date);
        if (!date.isValid() || date.isSame(dayjs())) {
            return undefined;
        }
        return toCalendarDate(fromDate(date.toDate(), getLocalTimeZone()));
    });

    const startTime = $derived.by(() => {
        const date = dayjs($formData.workshop_date);
        if (!date.isValid()) return '';
        return date.format('HH:mm');
    });

    const endTime = $derived.by(() => {
        const date = dayjs($formData.workshop_end_date);
        if (!date.isValid()) return '';
        return date.format('HH:mm');
    });

    function updateWorkshopDates(
        date?: CalendarDate | string,
        op: 'start' | 'end' | 'date' = 'date'
    ) {
        if (!date) return;

        if (typeof date === 'string' && op === 'start') {
            const [hour, minute] = date.split(':').map(Number);
            const currentDate = dayjs($formData.workshop_date);
            const baseDate = currentDate.isValid() ? currentDate : dayjs();
            $formData.workshop_date = baseDate.hour(hour).minute(minute).toDate();
            return;
        }

        if (typeof date === 'string' && op === 'end') {
            const [hour, minute] = date.split(':').map(Number);

            let baseDate = dayjs($formData.workshop_end_date);
            if (!baseDate.isValid()) {
                baseDate = dayjs($formData.workshop_date);
            }
            if (!baseDate.isValid()) {
                baseDate = dayjs();
            }

            $formData.workshop_end_date = baseDate.hour(hour).minute(minute).toDate();
            return;
        }

        // Handle date change (CalendarDate) - preserve existing times or use defaults
        if (typeof date !== 'string') {
            const startDate = dayjs($formData.workshop_date);
            const startTime = startDate.isValid()
                ? {hour: startDate.hour(), minute: startDate.minute()}
                : {hour: 10, minute: 0};

            const endDate = dayjs($formData.workshop_end_date);
            const endTime = endDate.isValid()
                ? {hour: endDate.hour(), minute: endDate.minute()}
                : {hour: 12, minute: 0};

            $formData.workshop_date = toCalendarDateTime(date).set(startTime).toDate(getLocalTimeZone());

            $formData.workshop_end_date = toCalendarDateTime(date)
                .set(endTime)
                .toDate(getLocalTimeZone());
        }
    }

    const isWorkshopEditable = $derived.by(() => {
        if (mode === 'create') return true;
        // For published workshops, always return false
        if (workshopStatus === 'published') return false;
        // Use the explicit workshopEditable prop if provided, otherwise fall back to status check
        if (workshopEditable !== undefined) return workshopEditable;
        return workshopStatus === 'planned';
    });

    const canEditPricing = $derived.by(() => {
        if (mode === 'create') return true;
        if (workshopStatus === 'planned') return true;
        return !priceEditingDisabled;
    });
</script>

<div class="space-y-8">
    {#if $message?.success}
        <Alert variant="default" class="border-green-200 bg-green-50">
            <CheckCircle class="h-4 w-4 text-green-600"/>
            <AlertDescription class="text-green-800">{$message.success}</AlertDescription>
        </Alert>
    {/if}

    {#if $message?.error}
        <Alert variant="destructive">
            <AlertDescription>{$message.error}</AlertDescription>
        </Alert>
    {/if}

    {#if !isWorkshopEditable}
        <Alert variant="default" class="border-yellow-200 bg-yellow-50">
            <AlertDescription class="text-yellow-800">
                {#if workshopStatus === 'published'}
                    This workshop cannot be edited because it has been published.
                {:else if workshopStatus === 'finished'}
                    This workshop cannot be edited because it has been finished.
                {:else if workshopStatus === 'cancelled'}
                    This workshop cannot be edited because it has been cancelled.
                {:else}
                    This workshop cannot be edited because it has been published, finished, or cancelled.
                {/if}
            </AlertDescription>
        </Alert>
    {/if}

    <form method="POST" use:enhance class="space-y-8 bg-white rounded-lg border shadow-sm p-6">
        <!-- Basic Information Section -->
        <div class="space-y-6">
            <h2 class="text-xl font-semibold text-gray-900 border-b pb-2">Basic Information</h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <Form.Field {form} name="title">
                    <Form.Control>
                        {#snippet children({props})}
                            <Form.Label>Title</Form.Label>
                            <Input
                                    {...props}
                                    bind:value={$formData.title}
                                    placeholder="Enter workshop title"
                                    disabled={!isWorkshopEditable}
                            />
                        {/snippet}
                    </Form.Control>
                    <Form.FieldErrors/>
                </Form.Field>

                <Form.Field {form} name="location">
                    <Form.Control>
                        {#snippet children({props})}
                            <Form.Label>Location</Form.Label>
                            <Input
                                    {...props}
                                    bind:value={$formData.location}
                                    placeholder="Enter workshop location"
                                    disabled={!isWorkshopEditable}
                            />
                        {/snippet}
                    </Form.Control>
                    <Form.FieldErrors/>
                </Form.Field>
            </div>

            <Form.Field {form} name="description">
                <Form.Control>
                    {#snippet children({props})}
                        <Form.Label>Description</Form.Label>
                        <Textarea
                                {...props}
                                bind:value={$formData.description}
                                placeholder="Enter workshop description"
                                rows={4}
                                disabled={!isWorkshopEditable}
                        />
                    {/snippet}
                </Form.Control>
                <Form.FieldErrors/>
            </Form.Field>
        </div>

        <!-- Date & Time Section -->
        <div class="space-y-6">
            <h2 class="text-xl font-semibold text-gray-900 border-b pb-2">Date & Time</h2>

            <Form.Field {form} name="workshop_date">
                <Form.Control>
                    {#snippet children({props})}
                        <Form.Label>Workshop Date & Time</Form.Label>
                        <div class="bg-gray-50 rounded-lg p-4">
                            <Calendar25
                                    id="workshop"
                                    date={workshopDateValue}
                                    {startTime}
                                    {endTime}
                                    onDateChange={(d) => updateWorkshopDates(d, 'date')}
                                    onStartTimeChange={(d) => updateWorkshopDates(d, 'start')}
                                    onEndTimeChange={(d) => updateWorkshopDates(d, 'end')}
                                    disabled={!isWorkshopEditable}
                            />
                        </div>
                        <input
                                {...props}
                                name="workshop_date"
                                type="datetime-local"
                                hidden
                                value={(() => {
							const date = dayjs($formData.workshop_date);
							return date.isValid() ? date.format('YYYY-MM-DDTHH:mm') : '';
						})()}
                                readonly
                        />
                        <input
                                name="workshop_end_date"
                                type="datetime-local"
                                hidden
                                value={(() => {
							const date = dayjs($formData.workshop_end_date);
							return date.isValid() ? date.format('YYYY-MM-DDTHH:mm') : '';
						})()}
                                readonly
                        />
                    {/snippet}
                </Form.Control>
                <Form.FieldErrors/>
            </Form.Field>

            <!-- Hidden field to capture workshop_end_date validation errors -->
            <Form.Field {form} name="workshop_end_date">
                <Form.Control>
                    <input type="hidden"/>
                </Form.Control>
                <Form.FieldErrors/>
            </Form.Field>
        </div>

        <!-- Workshop Details Section -->
        <div class="space-y-6">
            <h2 class="text-xl font-semibold text-gray-900 border-b pb-2">Workshop Details</h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <Form.Field {form} name="max_capacity">
                    <Form.Control>
                        {#snippet children({props})}
                            <Form.Label>Maximum Capacity</Form.Label>
                            <Input
                                    {...props}
                                    type="number"
                                    min="1"
                                    bind:value={$formData.max_capacity}
                                    placeholder="Enter maximum capacity"
                                    disabled={!isWorkshopEditable}
                            />
                        {/snippet}
                    </Form.Control>
                    <Form.FieldErrors/>
                </Form.Field>

                <Form.Field {form} name="refund_deadline_days">
                    <Form.Control>
                        {#snippet children({props})}
                            <Form.Label>Refund Deadline (days)</Form.Label>
                            <Input
                                    {...props}
                                    type="number"
                                    min="0"
                                    bind:value={$formData.refund_deadline_days}
                                    placeholder="3"
                                    disabled={!isWorkshopEditable}
                            />
                            <p class="text-sm text-muted-foreground mt-1">
                                Days before workshop when refunds are no longer available
                            </p>
                        {/snippet}
                    </Form.Control>
                    <Form.FieldErrors/>
                </Form.Field>
            </div>
        </div>

        <!-- Communication Settings Section (Create mode only) -->
        {#if mode === 'create'}
            <div class="space-y-6">
                <h2 class="text-xl font-semibold text-gray-900 border-b pb-2">Communication Settings</h2>

                <div class="bg-blue-50 rounded-lg p-4 border border-blue-200">
                    <p class="text-sm text-blue-700 mb-4">
                        All workshop status changes will be announced through selected channels
                    </p>

                    <div class="space-y-4">
                        <Form.Field {form} name="announce_discord">
                            <Form.Control>
                                {#snippet children({props})}
                                    <div class="flex items-center space-x-3">
                                        <Switch
                                                {...props}
                                                id="announce_discord"
                                                bind:checked={$formData.announce_discord}
                                        />
                                        <div>
                                            <Form.Label for="announce_discord" class="text-base font-medium"
                                            >Announce in Discord
                                            </Form.Label
                                            >
                                            <p class="text-sm text-blue-700">
                                                Send workshop announcements to the Discord server
                                            </p>
                                        </div>
                                    </div>
                                {/snippet}
                            </Form.Control>
                            <Form.FieldErrors/>
                        </Form.Field>

                        <Form.Field {form} name="announce_email">
                            <Form.Control>
                                {#snippet children({props})}
                                    <div class="flex items-center space-x-3">
                                        <Switch
                                                {...props}
                                                id="announce_email"
                                                bind:checked={$formData.announce_email}
                                        />
                                        <div>
                                            <Form.Label for="announce_email" class="text-base font-medium"
                                            >Announce via Email
                                            </Form.Label
                                            >
                                            <p class="text-sm text-blue-700">
                                                Send workshop announcements via email to all active members
                                            </p>
                                        </div>
                                    </div>
                                {/snippet}
                            </Form.Control>
                            <Form.FieldErrors/>
                        </Form.Field>
                    </div>
                </div>
            </div>
        {/if}

        <!-- Pricing & Access Section -->
        <div class="space-y-6">
            <h2 class="text-xl font-semibold text-gray-900 border-b pb-2">Pricing & Access</h2>

            {#if !canEditPricing}
                <Alert variant="default" class="border-orange-200 bg-orange-50">
                    <AlertDescription class="text-orange-800">
                        Pricing cannot be changed because there are already registered attendees.
                    </AlertDescription>
                </Alert>
            {/if}

            <Form.Field {form} name="is_public">
                <Form.Control>
                    {#snippet children({props})}
                        <div
                                class="flex items-center space-x-3 p-4 bg-blue-50 rounded-lg border border-blue-200"
                        >
                            <Switch
                                    {...props}
                                    id="is_public"
                                    bind:checked={$formData.is_public}
                                    disabled={!isWorkshopEditable}
                            />
                            <div>
                                <Form.Label for="is_public" class="text-base font-medium"
                                >Public Workshop
                                </Form.Label
                                >
                                <p class="text-sm text-blue-700 mt-1">
                                    Enable this to allow non-members to register for the workshop
                                </p>
                            </div>
                        </div>
                    {/snippet}
                </Form.Control>
                <Form.FieldErrors/>
            </Form.Field>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <Form.Field {form} name="price_member">
                    <Form.Control>
                        {#snippet children({props})}
                            <Form.Label>Member Price</Form.Label>
                            <div class="relative">
								<span
                                        class="absolute left-3 top-1/2 transform -translate-y-1/2 text-sm text-muted-foreground"
                                >€</span
                                >
                                <Input
                                        {...props}
                                        type="number"
                                        min="0"
                                        step="0.01"
                                        class="pl-8"
                                        bind:value={$formData.price_member}
                                        placeholder="10.00"
                                        disabled={!canEditPricing}
                                />
                            </div>
                        {/snippet}
                    </Form.Control>
                    <Form.FieldErrors/>
                </Form.Field>

                {#if $formData.is_public}
                    <Form.Field {form} name="price_non_member">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label>Non-Member Price</Form.Label>
                                <div class="relative">
									<span
                                            class="absolute left-3 top-1/2 transform -translate-y-1/2 text-sm text-muted-foreground"
                                    >€</span
                                    >
                                    <Input
                                            {...props}
                                            type="number"
                                            min="0"
                                            step="0.01"
                                            class="pl-8"
                                            bind:value={$formData.price_non_member}
                                            placeholder="20.00"
                                            disabled={!canEditPricing}
                                    />
                                </div>
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                {:else}
                    <div
                            class="flex items-center justify-center h-20 text-sm text-muted-foreground bg-gray-50 border border-dashed border-gray-300 rounded-lg"
                    >
                        <div class="text-center">
                            <p class="font-medium">Non-Member Pricing</p>
                            <p class="text-xs">Available for public workshops only</p>
                        </div>
                    </div>
                {/if}
            </div>
        </div>

        <!-- Submit Section -->
        <div class="pt-6 border-t">
            <Button
                    type="submit"
                    disabled={$submitting || !isWorkshopEditable}
                    class="w-full h-12 text-lg"
            >
                {#if $submitting}
                    <LoaderCircle class="mr-2 h-5 w-5"/>
                    {mode === 'create' ? 'Creating' : 'Updating'} Workshop...
                {:else}
                    {mode === 'create' ? 'Create' : 'Update'} Workshop
                {/if}
            </Button>
        </div>
    </form>
</div>
