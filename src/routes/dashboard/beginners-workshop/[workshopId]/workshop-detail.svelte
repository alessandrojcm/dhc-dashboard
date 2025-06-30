<script lang="ts">
  import { Badge } from '$lib/components/ui/badge';
  import { Button } from '$lib/components/ui/button';
  import dayjs from 'dayjs';
  import type { SupabaseClient } from '@supabase/supabase-js';
  import { createQuery } from '@tanstack/svelte-query';
	import { page } from '$app/state';
//   import { marked } from 'marked';
  let { supabase }: { supabase: SupabaseClient } = $props();
  let workshopId = $derived(page.params.workshopId);

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
        .throwOnError();
    }
  }));
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
    <div class="flex gap-2 mb-4">
      <Button size="sm" variant="outline">Edit</Button>
      <Button size="sm" variant="default">Publish</Button>
      <Button size="sm" variant="secondary">Finish</Button>
    </div>
    <!-- <div class="prose prose-sm max-w-none" use:html={marked(workshopQuery.data.notes_md)}></div> -->
  {/if}
</div> 