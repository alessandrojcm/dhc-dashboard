<script lang="ts">
  import WorkshopAttendees from './workshop-attendees.svelte';
  import WorkshopDetail from './workshop-detail.svelte';
  import { page } from '$app/state';
  let { data } = $props();
  const supabase = data.supabase;
  let workshopId = $derived(page.params.workshopId);
</script>

<div class="flex flex-col md:flex-row gap-4">
  <div class="md:w-1/3 w-full">
    <WorkshopAttendees supabase={supabase} />
  </div>
  <div class="md:w-2/3 w-full">
    <WorkshopDetail supabase={supabase} />
  </div>
</div> 