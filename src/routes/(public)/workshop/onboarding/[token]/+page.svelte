<script lang="ts">
  import * as Alert from '$lib/components/ui/alert';
  import { Button } from '$lib/components/ui/button';
  import * as Card from '$lib/components/ui/card';
  import * as Form from '$lib/components/ui/form';
  import { Input } from '$lib/components/ui/input';
  import { Checkbox } from '$lib/components/ui/checkbox';
  import * as RadioGroup from '$lib/components/ui/radio-group';
  import { onboardingSchema } from '$lib/schemas/workshopCreate';
  import { SocialMediaConsent } from '$lib/types';
  import { CheckCircled, ExclamationTriangle } from 'svelte-radix';
  import { toast } from 'svelte-sonner';
  import { superForm } from 'sveltekit-superforms';
  import { valibotClient } from 'sveltekit-superforms/adapters';
  import { LoaderCircle } from 'lucide-svelte';
  import dayjs from 'dayjs';

  const { data } = $props();
  const form = superForm(data.form, {
    validators: valibotClient(onboardingSchema),
    validationMethod: 'onblur'
  });
  const { form: formData, enhance, errors, submitting, message } = form;

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
  <title>Pre-Workshop Requirements - Dublin Hema Club</title>
</svelte:head>

<div class="container mx-auto max-w-2xl p-6">
  <Card.Root class="w-full">
    <Card.Header>
      <Card.Title class="text-2xl font-bold text-center">Pre-Workshop Requirements</Card.Title>
      <Card.Description class="text-center">
        Complete these requirements before attending your workshop
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
        <p class="text-blue-800">
          <strong>Attendee:</strong> {data.attendee.first_name} {data.attendee.last_name}
        </p>
      </div>

      <form method="POST" use:enhance>
        <!-- Insurance Confirmation -->
        <Form.Field {form} name="insuranceConfirmed">
          <Form.Control let:attrs>
            <div class="flex items-start space-x-3 mb-6">
              <Checkbox {...attrs} bind:checked={$formData.insuranceConfirmed} />
              <div class="grid gap-1.5 leading-none">
                <Form.Label class="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70">
                  Insurance Form Confirmation *
                </Form.Label>
                <p class="text-sm text-muted-foreground">
                  I confirm I have completed the 
                  <a href="https://hemaireland.com/insurance" target="_blank" class="text-blue-600 underline hover:text-blue-800">
                    HEMA Ireland Insurance form
                  </a>
                  (required for all participants)
                </p>
              </div>
            </div>
          </Form.Control>
          <Form.FieldErrors />
        </Form.Field>

        <!-- Media Consent -->
        <Form.Field {form} name="mediaConsent">
          <Form.Control let:attrs>
            <Form.Label class="text-sm font-medium mb-3">
              Photography & Social Media Consent (Optional)
            </Form.Label>
            <RadioGroup.Root {...attrs} bind:value={$formData.mediaConsent}>
              <div class="flex items-center space-x-2">
                <RadioGroup.Item value={SocialMediaConsent.no} id="consent-no" />
                <label 
                  for="consent-no" 
                  class="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70"
                >
                  No, I do not consent to photography/video
                </label>
              </div>
              <div class="flex items-center space-x-2">
                <RadioGroup.Item value={SocialMediaConsent.yes_unrecognizable} id="consent-unrecognizable" />
                <label 
                  for="consent-unrecognizable" 
                  class="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70"
                >
                  Yes, but only if my face is not clearly recognizable
                </label>
              </div>
              <div class="flex items-center space-x-2">
                <RadioGroup.Item value={SocialMediaConsent.yes_recognizable} id="consent-recognizable" />
                <label 
                  for="consent-recognizable" 
                  class="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70"
                >
                  Yes, I fully consent to photography/video for social media
                </label>
              </div>
            </RadioGroup.Root>
            <p class="text-sm text-muted-foreground mt-2">
              We may take photos/videos during the workshop for promotional purposes and social media
            </p>
          </Form.Control>
          <Form.FieldErrors />
        </Form.Field>

        <!-- Digital Signature -->
        <Form.Field {form} name="signature">
          <Form.Control let:attrs>
            <Form.Label>Digital Signature (Optional)</Form.Label>
            <Input {...attrs} bind:value={$formData.signature} placeholder="Type your full name" />
            <Form.Description>
              Providing your digital signature helps us confirm your identity and commitment to attend
            </Form.Description>
          </Form.Control>
          <Form.FieldErrors />
        </Form.Field>

        <!-- Information Alert -->
        <Alert.Root class="mb-6">
          <ExclamationTriangle class="h-4 w-4" />
          <Alert.Title>Important Information</Alert.Title>
          <Alert.Description>
            Once you complete these requirements, you'll be able to check in quickly on the day of the workshop using our QR code system. The insurance form is mandatory for all participants.
          </Alert.Description>
        </Alert.Root>

        <!-- Submit Button -->
        <Form.Button 
          disabled={!$formData.insuranceConfirmed || $submitting}
          class="w-full"
        >
          {#if $submitting}
            <LoaderCircle class="mr-2 h-4 w-4 animate-spin" />
            Completing...
          {:else}
            <CheckCircled class="mr-2 h-4 w-4" />
            Complete Pre-Workshop Setup
          {/if}
        </Form.Button>
      </form>
    </Card.Content>
  </Card.Root>
</div>
