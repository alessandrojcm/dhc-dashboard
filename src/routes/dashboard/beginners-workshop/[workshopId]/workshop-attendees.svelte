<script lang="ts">
  import {
    Root as SelectRoot,
    Trigger as SelectTrigger,
    Content as SelectContent,
    Item as SelectItem
  } from '$lib/components/ui/select';
  import { Badge } from '$lib/components/ui/badge';
  import { User } from 'lucide-svelte';
  import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
  import dayjs from 'dayjs';
  import type { SupabaseClient } from '@supabase/supabase-js';
  import { createQuery } from '@tanstack/svelte-query';
	import { page } from '$app/state';
  let { supabase }: { supabase: SupabaseClient } = $props();
  const workshopId = page.params.workshopId;
  let statusFilter = $state('all');

  // Fetch coolOffDays from the workshop
  const workshopQuery = createQuery(() => ({
    queryKey: ['workshop-cooloff', workshopId],
    enabled: !!workshopId,
    queryFn: async () => {
      if (!workshopId) return null;
      const { data, error } = await supabase
        .from('workshops')
        .select('id, cool_off_days')
        .eq('id', workshopId)
        .single();
      if (error) throw error;
      return data;
    }
  }));
  const coolOffDays = workshopQuery.data?.cool_off_days ?? 5;

  const attendeesQuery = createQuery(() => ({
    queryKey: ['workshop-attendees', workshopId, statusFilter],
    enabled: !!workshopId,
    queryFn: async ({ signal }) => {
      if (!workshopId) return [];
      let query = supabase
        .from('workshop_attendees')
        .select('id, status, invited_at, user_profile_id, user_profiles(first_name, last_name)')
        .eq('workshop_id', workshopId);
      if (statusFilter !== 'all') {
        query = query.eq('status', statusFilter);
      }
      return query
        .abortSignal(signal)
        .throwOnError()
        .then(({ data }) => data ?? []);
    }
  }));

  function coolOffPassed(emailedAt: string) {
    return dayjs().diff(dayjs(emailedAt), 'day') > coolOffDays;
  }

  function getProfileName(user_profiles: any): string {
    if (Array.isArray(user_profiles) && user_profiles.length > 0) {
      return `${user_profiles[0]?.first_name ?? ''} ${user_profiles[0]?.last_name ?? ''}`.trim();
    } else if (user_profiles && typeof user_profiles === 'object') {
      return `${user_profiles.first_name ?? ''} ${user_profiles.last_name ?? ''}`.trim();
    }
    return '';
  }

  function statusColor(status: string) {
    if (status === 'confirmed' || status === 'attended') return 'success';
    if (status === 'invited') return 'info';
    if (status === 'cancelled' || status === 'no_show') return 'destructive';
    return 'outline';
  }
</script>

<div class="bg-card border rounded-lg shadow-md p-6 h-full flex flex-col">
  <div class="flex items-center justify-between mb-4 gap-2 flex-wrap">
    <div class="flex items-center gap-2">
      <h3 class="font-bold text-lg">Attendees</h3>
      <Badge variant="secondary" class="text-xs px-2 py-1">{attendeesQuery.data ? attendeesQuery.data.length : 0}</Badge>
    </div>
    <SelectRoot type="single" value={statusFilter} onValueChange={(v: string) => statusFilter = v}>
      <SelectTrigger class="w-36 h-8 text-xs border" aria-label="Filter by status">
        <span class="mr-2">{statusFilter === 'all' ? 'All Statuses' : statusFilter.charAt(0).toUpperCase() + statusFilter.slice(1)}</span>
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="all">All</SelectItem>
        <SelectItem value="invited">Invited</SelectItem>
        <SelectItem value="confirmed">Confirmed</SelectItem>
        <SelectItem value="attended">Attended</SelectItem>
      </SelectContent>
    </SelectRoot>
  </div>
  <div class="flex-1 overflow-y-auto divide-y">
    {#if !workshopId}
      <div class="flex flex-col items-center justify-center h-48 text-muted-foreground text-sm py-8 text-center">
        <User class="w-8 h-8 mb-2 opacity-60" />
        Select a workshop to view attendees
      </div>
    {:else if attendeesQuery.isLoading || workshopQuery.isLoading}
      <div class="flex flex-col items-center justify-center h-48 text-muted-foreground text-sm py-8 text-center">
        <LoaderCircle class="w-6 h-6 mb-2 animate-spin" />
        Loading attendees...
      </div>
    {:else if attendeesQuery.isError || workshopQuery.isError}
      <div class="flex flex-col items-center justify-center h-48 text-red-600 text-sm py-8 text-center">
        Error loading attendees or workshop info
      </div>
    {:else if !attendeesQuery.data || attendeesQuery.data.length === 0}
      <div class="flex flex-col items-center justify-center h-48 text-muted-foreground text-sm py-8 text-center">
        <User class="w-8 h-8 mb-2 opacity-60" />
        No attendees found for this workshop
      </div>
    {:else}
      <ul class="divide-y">
        {#each attendeesQuery.data as attendee: any}
          <li class="flex items-center justify-between py-4 gap-2">
            <div>
              <div class="font-medium text-base">{getProfileName(attendee.user_profiles)}</div>
              <div class="text-xs text-muted-foreground">Emailed: {dayjs(attendee.invited_at).format('YYYY-MM-DD')}</div>
            </div>
            <div class="flex flex-col items-end gap-1 min-w-[110px]">
              <Badge variant={statusColor(attendee.status)} class="text-xs capitalize">{attendee.status}</Badge>
              <span class="text-xs">
                {coolOffPassed(attendee.invited_at)
                  ? 'Cool-off passed'
                  : `In cool-off (${coolOffDays - dayjs().diff(dayjs(attendee.invited_at), 'day')}d left)`}
              </span>
            </div>
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</div> 