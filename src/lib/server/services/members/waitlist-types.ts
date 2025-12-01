import type { Database } from '$database';

// Waitlist entry types from database
export type WaitlistEntry = Database['public']['Tables']['waitlist']['Row'];
export type WaitlistEntryInsert = Database['public']['Tables']['waitlist']['Insert'];
export type WaitlistEntryUpdate = Database['public']['Tables']['waitlist']['Update'];
export type WaitlistStatus = Database['public']['Enums']['waitlist_status'];

// Guardian types from database
export type WaitlistGuardian = Database['public']['Tables']['waitlist_guardians']['Row'];
export type WaitlistGuardianInsert = Database['public']['Tables']['waitlist_guardians']['Insert'];
export type WaitlistGuardianUpdate = Database['public']['Tables']['waitlist_guardians']['Update'];

// Result type from insert_waitlist_entry function
export type InsertWaitlistEntryResult =
	Database['public']['Functions']['insert_waitlist_entry']['Returns'][0];
