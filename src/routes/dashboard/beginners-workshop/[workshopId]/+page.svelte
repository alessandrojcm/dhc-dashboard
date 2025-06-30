<script lang="ts">
  import WorkshopAttendees from './workshop-attendees.svelte';
  import WorkshopDetail from './workshop-detail.svelte';
  let { data } = $props();
  const supabase = data.supabase;
</script>

<div class="flex h-[calc(100vh-64px)] bg-muted gap-6 p-6">
  <div class="flex-1 min-w-0 h-full flex flex-col">
    <WorkshopAttendees supabase={supabase} />
  </div>
  <div class="w-[350px] max-w-sm h-full flex flex-col">
    <WorkshopDetail supabase={supabase} />
  </div>
</div> 