<script lang="ts">
  import { createQuery } from '@tanstack/svelte-query';
  import * as Tabs from '$lib/components/ui/tabs/index.js';
  import Analytics from './member-analytics.svelte';

  const { data } = $props();
  const supabase = $derived(data.supabase);

  const membersQuery = createQuery(() =>({
    queryKey: ['members'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('members')
        .select('*')
        .order('last_name');
      
      if (error) throw error;
      return data;
    }
  }));
  let value = $state('dashboard')
</script>

<Tabs.Root bind:value class="p-2 min-h-96 mr-2">
	<Tabs.List>
		<Tabs.Trigger value="dashboard">Dashboard</Tabs.Trigger>
		<Tabs.Trigger value="waitlist">Waitlist</Tabs.Trigger>
	</Tabs.List>
	<Tabs.Content value="dashboard">
		<Analytics {supabase} />
	</Tabs.Content>
	<!-- <Tabs.Content value="waitlist">
		<WaitlistTable {supabase} />
	</Tabs.Content> -->
</Tabs.Root>