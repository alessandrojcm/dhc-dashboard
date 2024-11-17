<script lang="ts">
	import { cn } from '$lib/utils.js';
	import * as Avatar from '$lib/components/ui/avatar';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import { Button } from '$lib/components/ui/button';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import type { UserData } from '$lib/types';

	type Props = {
		className?: string | undefined | null;
		logout: () => void;
		userData: Promise<UserData>;
	};

	let { className = undefined, logout, userData }: Props = $props();
</script>

<nav class={cn('flex items-center space-x-4 lg:space-x-6 border-solid p-2 px-16 border-0.5 rounder-md shadow-md', className)}>
	<DropdownMenu.Root>
		<DropdownMenu.Trigger asChild let:builder>
			<Button variant="ghost" builders={[builder]} class="relative h-8 w-8 rounded-full ml-auto">
				<Avatar.Root class="h-8 w-8">
					<Avatar.Fallback>SC</Avatar.Fallback>
				</Avatar.Root>
			</Button>
		</DropdownMenu.Trigger>
		<DropdownMenu.Content class="w-56" align="end">
			<DropdownMenu.Label class="font-normal">
				{#await userData}
					<Skeleton class="h-[50px]" />
				{:then user}
					<div class="flex flex-col space-y-1">
						<p class="text-sm font-medium leading-none">{user.firstName} {user.lastName}</p>
						<p class="text-muted-foreground text-xs leading-none">{user.email}</p>
					</div>
				{/await}
			</DropdownMenu.Label>
			<DropdownMenu.Separator />
			<DropdownMenu.Item onclick={logout}>Log out</DropdownMenu.Item>
		</DropdownMenu.Content>
	</DropdownMenu.Root>
</nav>
