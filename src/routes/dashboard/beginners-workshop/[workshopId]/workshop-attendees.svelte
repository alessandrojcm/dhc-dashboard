<script lang="ts">
  import {
    Root as SelectRoot,
    Trigger as SelectTrigger,
    Content as SelectContent,
    Item as SelectItem
  } from '$lib/components/ui/select';
  import { Badge } from '$lib/components/ui/badge';
  import dayjs from 'dayjs';
  import type { SupabaseClient } from '@supabase/supabase-js';
  import { createQuery } from '@tanstack/svelte-query';
	import { page } from '$app/state';
  let { workshopId, supabase }: { workshopId: string | null, supabase: SupabaseClient } = $props();
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
</script>

<div class="bg-card border rounded-lg p-4 h-full flex flex-col">
  <div class="flex items-center justify-between mb-2">
    <h3 class="font-semibold text-base">Attendees <span class="ml-1 text-xs text-muted-foreground">{attendeesQuery.data ? attendeesQuery.data.length : 0}</span></h3>
    <SelectRoot type="single" value={statusFilter} onValueChange={(v: string) => statusFilter = v}>
      <SelectTrigger class="w-28 h-8 text-xs">{statusFilter === 'all' ? 'All Statuses' : statusFilter.charAt(0).toUpperCase() + statusFilter.slice(1)}</SelectTrigger>
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
      <div class="text-muted-foreground text-sm py-8 text-center">Select a workshop to view attendees</div>
    {:else if attendeesQuery.isLoading || workshopQuery.isLoading}
      <div class="text-muted-foreground text-sm py-8 text-center">Loading...</div>
    {:else if attendeesQuery.isError || workshopQuery.isError}
      <div class="text-red-600 text-sm py-8 text-center">Error loading attendees or workshop info</div>
    {:else if !attendeesQuery.data || attendeesQuery.data.length === 0}
      <div class="text-muted-foreground text-sm py-8 text-center">No attendees found</div>
    {:else}
      {#each attendeesQuery.data as attendee: any}
        <div class="flex items-center justify-between py-3">
          <div>
            <div class="font-medium text-sm">{getProfileName(attendee.user_profiles)}</div>
            <div class="text-xs text-muted-foreground">Emailed: {dayjs(attendee.invited_at).format('YYYY-MM-DD')}</div>
          </div>
          <div class="flex flex-col items-end gap-1">
            <Badge variant="outline" class="text-xs">{attendee.status}</Badge>
            <span class="text-xs">
              {coolOffPassed(attendee.invited_at)
                ? 'Cool-off passed'
                : `In cool-off (${coolOffDays - dayjs().diff(dayjs(attendee.invited_at), 'day')}d left)`}
            </span>
          </div>
        </div>
      {/each}
    {/if}
  </div>
</div> 