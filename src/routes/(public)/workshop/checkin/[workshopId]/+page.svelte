<script lang="ts">
  import { page } from '$app/state';
  import * as Alert from '$lib/components/ui/alert';
  import { Button } from '$lib/components/ui/button';
  import * as Card from '$lib/components/ui/card';
  import * as Form from '$lib/components/ui/form';
  import * as Select from '$lib/components/ui/select';
  import { checkinSchema } from '$lib/schemas/workshopCreate';
  import { CheckCircled, ExclamationTriangle } from 'svelte-radix';
  import { toast } from 'svelte-sonner';
  import { superForm } from 'sveltekit-superforms';
  import { valibotClient } from 'sveltekit-superforms/adapters';
  import { LoaderCircle } from 'lucide-svelte';
  import dayjs from 'dayjs';

  const { data } = $props();
  
  const form = superForm({ ...data.form }, {
    validators: valibotClient(checkinSchema),
    validationMethod: 'onblur',
    onUpdated: ({ form }) => {
      if (form.message?.success) {
        // Reset the form and refresh the page to update attendee lists
        form.data.attendeeEmail = '';
        window.location.reload();
      }
    }
  });
  const { form: formData, enhance, submitting, message } = form;
  $formData.workshopId = page.params.workshopId;

  // Filter out already checked-in attendees
  const availableAttendees = $derived(
    data.attendees.filter(attendee => !attendee.checkedIn)
  );

  const checkedInAttendees = $derived(
    data.attendees.filter(attendee => attendee.checkedIn)
  );

  $effect(() => {
    const unsubscribe = message.subscribe((message) => {
      if (message?.error) {
        toast.error(message.error);
      } else if (message?.success) {
        toast.success(message.success);
      }
    });

    return unsubscribe;
  });
</script>

<svelte:head>
  <title>Workshop Check-In - Dublin Hema Club</title>
</svelte:head>

<div class="container mx-auto max-w-4xl p-6">
  <Card.Root class="w-full">
    <Card.Header>
      <Card.Title class="text-2xl font-bold text-center">Workshop Check-In</Card.Title>
      <Card.Description class="text-center">
        Select your name below to check in to today's workshop
      </Card.Description>
    </Card.Header>
    
    <Card.Content>
      <!-- Workshop Information -->
      <div class="mb-6 p-4 bg-blue-50 border border-blue-200 rounded-lg">
        <h3 class="font-semibold text-blue-900 mb-2">Workshop Details</h3>
        <p class="text-blue-800">
          <strong>Date:</strong> {dayjs(data.workshop.date).format('dddd, MMMM D, YYYY')}
        </p>
        <p class="text-blue-800">
          <strong>Location:</strong> {data.workshop.location}
        </p>
      </div>

      <!-- Check-in Form -->
      <form method="POST" use:enhance class="space-y-4 mb-6">
        <Form.Field {form} name="attendeeEmail">
          <Form.Control let:attrs>
            <Form.Label>Select your name:</Form.Label>
            <Select.Root bind:selected={$formData.attendeeEmail}>
              <Select.Trigger class="w-full">
                <Select.Value placeholder="-- Choose your name --" />
              </Select.Trigger>
              <Select.Content>
                {#each availableAttendees as attendee}
                  <Select.Item value={attendee.email}>
                    {attendee.name}
                    {#if attendee.status === 'pre_checked'}
                      <span class="ml-2 text-green-600">✓ Pre-checked</span>
                    {:else}
                      <span class="ml-2 text-yellow-600">⚠️ Needs onboarding</span>
                    {/if}
                  </Select.Item>
                {/each}
              </Select.Content>
            </Select.Root>
          </Form.Control>
          <Form.FieldErrors />
        </Form.Field>

        <Form.Button 
          disabled={!$formData.attendeeEmail || $submitting}
          class="w-full"
        >
          {#if $submitting}
            <LoaderCircle class="mr-2 h-4 w-4 animate-spin" />
            Checking In...
          {:else}
            <CheckCircled class="mr-2 h-4 w-4" />
            Check In
          {/if}
        </Form.Button>

        {#if availableAttendees.length === 0}
          <Alert.Root>
            <ExclamationTriangle class="h-4 w-4" />
            <Alert.Title>No Available Check-ins</Alert.Title>
            <Alert.Description>
              All attendees have already checked in, or there are no confirmed attendees for this workshop.
            </Alert.Description>
          </Alert.Root>
        {/if}
      </form>

      <!-- Attendance Summary -->
      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <!-- Checked In -->
        <div>
          <h3 class="font-semibold text-green-800 mb-3">
            ✅ Checked In ({checkedInAttendees.length})
          </h3>
          <div class="space-y-2 max-h-60 overflow-y-auto">
            {#each checkedInAttendees as attendee}
              <div class="p-2 bg-green-50 border border-green-200 rounded text-sm">
                <div class="font-medium">{attendee.name}</div>
                {#if attendee.checkedInAt}
                  <div class="text-green-600 text-xs">
                    Checked in at {dayjs(attendee.checkedInAt).format('HH:mm')}
                  </div>
                {/if}
              </div>
            {/each}
          </div>
        </div>

        <!-- Waiting to Check In -->
        <div>
          <h3 class="font-semibold text-yellow-800 mb-3">
            ⏳ Waiting to Check In ({availableAttendees.length})
          </h3>
          <div class="space-y-2 max-h-60 overflow-y-auto">
            {#each availableAttendees as attendee}
              <div class="p-2 bg-yellow-50 border border-yellow-200 rounded text-sm">
                <div class="font-medium">{attendee.name}</div>
                <div class="text-yellow-600 text-xs">
                  {attendee.status === 'pre_checked' ? 'Pre-workshop requirements completed' : 'Needs to complete pre-workshop requirements'}
                </div>
              </div>
            {/each}
          </div>
        </div>
      </div>

      <!-- Information -->
      <Alert.Root class="mt-6">
        <ExclamationTriangle class="h-4 w-4" />
        <Alert.Title>Need Help?</Alert.Title>
        <Alert.Description>
          If you don't see your name in the list or are having trouble checking in, please speak to one of the coaches or volunteers. 
          Make sure you've completed your payment and any pre-workshop requirements.
        </Alert.Description>
      </Alert.Root>
    </Card.Content>
  </Card.Root>
</div>
