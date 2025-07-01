<script lang="ts">
  import { Badge } from '$lib/components/ui/badge';
  import { Button } from '$lib/components/ui/button';
  import dayjs from 'dayjs';
  import type { SupabaseClient } from '@supabase/supabase-js';
  import { createQuery, createMutation } from '@tanstack/svelte-query';
  import { page } from '$app/state';
  import { toast } from 'svelte-sonner';
  import { invalidate } from '$app/navigation';
  import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
  import * as Command from '$lib/components/ui/command/index.js';
  import * as Popover from '$lib/components/ui/popover/index.js';
  import { UserPlus, Trash2, ChevronsUpDown, Check } from 'lucide-svelte';
//   import { marked } from 'marked';
  let { supabase }: { supabase: SupabaseClient } = $props();
  let workshopId = $derived(page.params.workshopId);
  let commandOpen = $state(false);
  let searchQuery = $state('');

  const workshopQuery = createQuery(() => ({
    queryKey: ['workshop', workshopId],
    enabled: !!workshopId,
    queryFn: async ({ signal }) => {
      if (!workshopId) return null;
      return supabase
        .from('workshops')
        .select('id, workshop_date, location, status, capacity, batch_size, cool_off_days, notes_md, coach:user_profiles!workshops_coach_id_fkey(first_name, last_name)')
        .eq('id', workshopId)
        .abortSignal(signal)
        .single()
        .throwOnError()
        .then(data => data.data);
    }
  }));

  // Query for manually added attendees (those added before publishing)
  const manualAttendeesQuery = createQuery(() => ({
    queryKey: ['manual-attendees', workshopId],
    enabled: !!workshopId,
    queryFn: async ({ signal }) => {
      if (!workshopId) return [];
      const { data, error } = await supabase
        .from('workshop_attendees')
        .select('id, user_profile_id, priority, user_profiles(first_name, last_name, waitlist:waitlist(email))')
        .eq('workshop_id', workshopId)
        .is('invited_at', null) // Only show manually added attendees (not yet invited)
        .abortSignal(signal);
      
      if (error) throw error;
      return data ?? [];
    }
  }));

  const publishMutation = createMutation(() => ({
    mutationFn: async (id: string) => {
      const response = await fetch(`/api/workshops/${id}/publish`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
        },
      });

      if (!response.ok) {
        const error = await response.json().catch(() => ({ message: 'Failed to publish workshop' }));
        throw new Error(error.message || 'Failed to publish workshop');
      }

      return response.json();
    },
    onSuccess: () => {
      toast.success('Workshop published successfully!');
      // Invalidate the workshop query to refetch the updated data
      workshopQuery.refetch();
      manualAttendeesQuery.refetch();
      // Also invalidate the workshop list
      invalidate('/dashboard/beginners-workshop');
    },
    onError: (error: Error) => {
      toast.error(error.message || 'Failed to publish workshop');
    }
  }));

  const addAttendeeMutation = createMutation(() => ({
    mutationFn: async ({ workshopId, userId, priority = 1 }: { workshopId: string; userId: string; priority?: number }) => {
      const response = await fetch(`/api/workshops/${workshopId}/attendees`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          user_profile_id: userId,
          priority
        }),
      });

      if (!response.ok) {
        const error = await response.json().catch(() => ({ message: 'Failed to add attendee' }));
        throw new Error(error.message || 'Failed to add attendee');
      }

      return response.json();
    },
    onSuccess: () => {
      toast.success('Attendee added successfully!');
      manualAttendeesQuery.refetch();
      // Clear search and close popover
      searchQuery = '';
      commandOpen = false;
    },
    onError: (error: Error) => {
      toast.error(error.message || 'Failed to add attendee');
    }
  }));

  const removeAttendeeMutation = createMutation(() => ({
    mutationFn: async ({ workshopId, attendeeId }: { workshopId: string; attendeeId: string }) => {
      const response = await fetch(`/api/workshops/${workshopId}/attendees?attendee_id=${attendeeId}`, {
        method: 'DELETE',
      });

      if (!response.ok) {
        const error = await response.json().catch(() => ({ message: 'Failed to remove attendee' }));
        throw new Error(error.message || 'Failed to remove attendee');
      }

      return response.json();
    },
    onSuccess: () => {
      toast.success('Attendee removed successfully!');
      manualAttendeesQuery.refetch();
    },
    onError: (error: Error) => {
      toast.error(error.message || 'Failed to remove attendee');
    }
  }));

  // User search query - search waitlist users who haven't been added to this workshop
  const userSearchQuery = createQuery(() => ({
    queryKey: ['user-search', searchQuery, workshopId],
    enabled: !!searchQuery && searchQuery.length >= 2 && !!workshopId,
    queryFn: async ({ signal }) => {
      if (!searchQuery || searchQuery.length < 2 || !workshopId) return [];
      
      const response = await fetch(`/api/workshops/${workshopId}/search-users?q=${encodeURIComponent(searchQuery)}`, {
        signal
      });
      
      if (!response.ok) {
        console.error('User search error:', response.statusText);
        return [];
      }
      
      return await response.json();
    }
  }));


  function handlePublish() {
    if (!workshopId || !workshopQuery.data) return;
    publishMutation.mutate(workshopId);
  }

  function handleAddAttendee(userId: string) {
    if (!workshopId) return;
    addAttendeeMutation.mutate({ workshopId, userId });
  }

  function handleRemoveAttendee(attendeeId: string) {
    if (!workshopId) return;
    removeAttendeeMutation.mutate({ workshopId, attendeeId });
  }

  function getAttendeeEmail(attendee: any): string {
    return attendee.user_profiles?.waitlist?.email || 'No email';
  }

  function getAttendeeName(attendee: any): string {
    const profile = attendee.user_profiles;
    if (!profile) return 'Unknown';
    return `${profile.first_name || ''} ${profile.last_name || ''}`.trim() || 'Unknown';
  }
  $inspect(workshopQuery.data);
</script>

<div class="bg-card border rounded-lg p-4 h-full flex flex-col">
  {#if !workshopId}
    <div class="text-muted-foreground text-sm py-8 text-center">Select a workshop to view details</div>
  {:else if workshopQuery.isLoading}
    <div class="text-muted-foreground text-sm py-8 text-center">Loading...</div>
  {:else if workshopQuery.isError}
    <div class="text-red-600 text-sm py-8 text-center">Error loading workshop details</div>
  {:else if !workshopQuery.data}
    <div class="text-muted-foreground text-sm py-8 text-center">Workshop not found</div>
  {:else}
    <div class="flex items-center justify-between mb-2">
      <h3 class="font-semibold text-base">Workshop Details</h3>
      <Badge variant={workshopQuery.data.status === 'draft' ? 'default' : 'outline'} class="capitalize text-xs">{workshopQuery.data.status}</Badge>
    </div>
    <div class="grid grid-cols-2 gap-2 text-sm mb-2">
      <div class="font-medium">Date:</div>
      <div>{dayjs(workshopQuery.data.workshop_date).format('YYYY-MM-DD HH:mm')}</div>
      <div class="font-medium">Location:</div>
      <div>{workshopQuery.data.location}</div>
      <div class="font-medium">Coach:</div>
      <div>{workshopQuery.data.coach?.first_name} {workshopQuery.data.coach?.last_name}</div>
      <div class="font-medium">Capacity:</div>
      <div>{workshopQuery.data.capacity}</div>
      <div class="font-medium">Batch Size:</div>
      <div>{workshopQuery.data.batch_size}</div>
      <div class="font-medium">Cool-off Days:</div>
      <div>{workshopQuery.data.cool_off_days}</div>
    </div>

    <!-- Manual Attendees Section - Show for all workshop statuses -->
      <div class="mb-4">
        <div class="flex items-center justify-between mb-2">
          <h4 class="font-medium text-sm">Priority Attendees</h4>
          <Popover.Root bind:open={commandOpen}>
            <Popover.Trigger>
              <Button size="sm" variant="outline" role="combobox" aria-expanded={commandOpen}>
                <UserPlus class="mr-1 h-3 w-3" />
                Add Attendee
                <ChevronsUpDown class="ml-1 h-3 w-3 opacity-50" />
              </Button>
            </Popover.Trigger>
            <Popover.Content class="w-80 p-0" align="end">
              <Command.Root shouldFilter={false}>
                <Command.Input
                  placeholder="Search by name or email..."
                  bind:value={searchQuery}
                  class="h-9"
                />
                <Command.List class="max-h-60">
                  {#if userSearchQuery.isLoading}
                    <div class="flex items-center justify-center py-6">
                      <LoaderCircle class="h-4 w-4 animate-spin" />
                    </div>
                  {:else if userSearchQuery.data && userSearchQuery.data.length > 0}
                    <Command.Group heading="Available Users">
                      {#each userSearchQuery.data as user}
                        <Command.Item
                          value={user.id}
                          onSelect={() => handleAddAttendee(user.id)}
                          class="flex items-center justify-between cursor-pointer"
                          disabled={addAttendeeMutation.isPending}
                        >
                          <div class="flex-1">
                            <div class="font-medium text-sm">{user.full_name}</div>
                            <div class="text-xs text-muted-foreground">{user.email || 'No email'}</div>
                          </div>
                          {#if addAttendeeMutation.isPending}
                            <LoaderCircle class="h-3 w-3 animate-spin" />
                          {:else}
                            <Check class="h-3 w-3 opacity-0 group-data-[selected]:opacity-100" />
                          {/if}
                        </Command.Item>
                      {/each}
                    </Command.Group>
                  {:else if searchQuery.length >= 2}
                    <Command.Empty>No users found.</Command.Empty>
                  {:else if searchQuery.length < 2 && searchQuery.length > 0}
                    <Command.Empty>Type at least 2 characters to search.</Command.Empty>
                  {:else}
                    <Command.Empty>Start typing to search for users.</Command.Empty>
                  {/if}
                </Command.List>
              </Command.Root>
            </Popover.Content>
          </Popover.Root>
        </div>
        
        {#if manualAttendeesQuery.isLoading}
          <div class="text-muted-foreground text-xs py-2">Loading attendees...</div>
        {:else if manualAttendeesQuery.data && manualAttendeesQuery.data.length > 0}
          <div class="space-y-1 max-h-32 overflow-y-auto">
            {#each manualAttendeesQuery.data as attendee}
              <div class="flex items-center justify-between p-2 bg-muted rounded text-xs">
                <div class="flex-1">
                  <div class="font-medium">{getAttendeeName(attendee)}</div>
                  <div class="text-muted-foreground">{getAttendeeEmail(attendee)}</div>
                </div>
                <Button 
                  size="sm" 
                  variant="ghost"
                  onclick={() => handleRemoveAttendee(attendee.id)}
                  disabled={removeAttendeeMutation.isPending}
                  class="h-6 w-6 p-0"
                >
                  <Trash2 class="h-3 w-3" />
                </Button>
              </div>
            {/each}
          </div>
        {:else}
          <div class="text-muted-foreground text-xs py-2">No priority attendees added yet</div>
        {/if}
      </div>

    <div class="flex gap-2 mb-4">
      <Button size="sm" variant="outline">Edit</Button>
      <Button 
        size="sm" 
        variant="default" 
        onclick={handlePublish}
        disabled={workshopQuery.data.status !== 'draft' || publishMutation.isPending}
      >
        {#if publishMutation.isPending}
          <LoaderCircle class="mr-2 h-4 w-4" />
        {/if}
        Publish
      </Button>
      <Button 
        size="sm" 
        variant="secondary"
        disabled={workshopQuery.data.status !== 'published'}
      >
        Finish
      </Button>
    </div>
    <!-- <div class="prose prose-sm max-w-none" use:html={marked(workshopQuery.data.notes_md)}></div> -->
  {/if}
</div> 
