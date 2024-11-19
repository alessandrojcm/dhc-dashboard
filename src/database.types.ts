export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export type Database = {
	graphql_public: {
		Tables: {
			[_ in never]: never;
		};
		Views: {
			[_ in never]: never;
		};
		Functions: {
			graphql: {
				Args: {
					operationName?: string;
					query?: string;
					variables?: Json;
					extensions?: Json;
				};
				Returns: Json;
			};
		};
		Enums: {
			[_ in never]: never;
		};
		CompositeTypes: {
			[_ in never]: never;
		};
	};
	public: {
		Tables: {
			user_audit_log: {
				Row: {
					action: string;
					created_at: string | null;
					details: Json | null;
					id: string;
					ip_address: string | null;
					user_id: string | null;
				};
				Insert: {
					action: string;
					created_at?: string | null;
					details?: Json | null;
					id?: string;
					ip_address?: string | null;
					user_id?: string | null;
				};
				Update: {
					action?: string;
					created_at?: string | null;
					details?: Json | null;
					id?: string;
					ip_address?: string | null;
					user_id?: string | null;
				};
				Relationships: [];
			};
			user_profiles: {
				Row: {
					created_at: string | null;
					first_name: string;
					id: string;
					is_active: boolean | null;
					last_name: string;
					updated_at: string | null;
				};
				Insert: {
					created_at?: string | null;
					first_name: string;
					id: string;
					is_active?: boolean | null;
					last_name: string;
					updated_at?: string | null;
				};
				Update: {
					created_at?: string | null;
					first_name?: string;
					id?: string;
					is_active?: boolean | null;
					last_name?: string;
					updated_at?: string | null;
				};
				Relationships: [];
			};
			user_roles: {
				Row: {
					id: number;
					role: Database['public']['Enums']['role_type'];
					user_id: string;
				};
				Insert: {
					id?: number;
					role: Database['public']['Enums']['role_type'];
					user_id: string;
				};
				Update: {
					id?: number;
					role?: Database['public']['Enums']['role_type'];
					user_id?: string;
				};
				Relationships: [];
			};
			waitlist: {
				Row: {
					admin_notes: string | null;
					date_of_birth: string;
					email: string;
					first_name: string;
					id: string;
					initial_registration_date: string | null;
					insurance_form_submitted: boolean | null;
					last_contacted: string | null;
					last_name: string;
					last_status_change: string | null;
					medical_conditions: string | null;
					phone_number: string;
					status: Database['public']['Enums']['waitlist_status'];
				};
				Insert: {
					admin_notes?: string | null;
					date_of_birth: string;
					email: string;
					first_name: string;
					id?: string;
					initial_registration_date?: string | null;
					insurance_form_submitted?: boolean | null;
					last_contacted?: string | null;
					last_name: string;
					last_status_change?: string | null;
					medical_conditions?: string | null;
					phone_number: string;
					status?: Database['public']['Enums']['waitlist_status'];
				};
				Update: {
					admin_notes?: string | null;
					date_of_birth?: string;
					email?: string;
					first_name?: string;
					id?: string;
					initial_registration_date?: string | null;
					insurance_form_submitted?: boolean | null;
					last_contacted?: string | null;
					last_name?: string;
					last_status_change?: string | null;
					medical_conditions?: string | null;
					phone_number?: string;
					status?: Database['public']['Enums']['waitlist_status'];
				};
				Relationships: [];
			};
			waitlist_status_history: {
				Row: {
					changed_at: string | null;
					changed_by: string | null;
					id: string;
					new_status: Database['public']['Enums']['waitlist_status'];
					notes: string | null;
					old_status: Database['public']['Enums']['waitlist_status'] | null;
					waitlist_id: string | null;
				};
				Insert: {
					changed_at?: string | null;
					changed_by?: string | null;
					id?: string;
					new_status: Database['public']['Enums']['waitlist_status'];
					notes?: string | null;
					old_status?: Database['public']['Enums']['waitlist_status'] | null;
					waitlist_id?: string | null;
				};
				Update: {
					changed_at?: string | null;
					changed_by?: string | null;
					id?: string;
					new_status?: Database['public']['Enums']['waitlist_status'];
					notes?: string | null;
					old_status?: Database['public']['Enums']['waitlist_status'] | null;
					waitlist_id?: string | null;
				};
				Relationships: [
					{
						foreignKeyName: 'waitlist_status_history_waitlist_id_fkey';
						columns: ['waitlist_id'];
						isOneToOne: false;
						referencedRelation: 'waitlist';
						referencedColumns: ['id'];
					},
					{
						foreignKeyName: 'waitlist_status_history_waitlist_id_fkey';
						columns: ['waitlist_id'];
						isOneToOne: false;
						referencedRelation: 'waitlist_management_view';
						referencedColumns: ['id'];
					}
				];
			};
		};
		Views: {
			waitlist_management_view: {
				Row: {
					admin_notes: string | null;
					age: number | null;
					current_position: number | null;
					date_of_birth: string | null;
					email: string | null;
					first_name: string | null;
					full_name: string | null;
					id: string | null;
					initial_registration_date: string | null;
					insurance_form_submitted: boolean | null;
					last_contacted: string | null;
					last_name: string | null;
					last_status_change: string | null;
					medical_conditions: string | null;
					never_invited: boolean | null;
					phone_number: string | null;
					status: Database['public']['Enums']['waitlist_status'] | null;
				};
				Insert: {
					admin_notes?: string | null;
					age?: never;
					current_position?: never;
					date_of_birth?: string | null;
					email?: string | null;
					first_name?: string | null;
					full_name?: never;
					id?: string | null;
					initial_registration_date?: string | null;
					insurance_form_submitted?: boolean | null;
					last_contacted?: string | null;
					last_name?: string | null;
					last_status_change?: string | null;
					medical_conditions?: string | null;
					never_invited?: never;
					phone_number?: string | null;
					status?: Database['public']['Enums']['waitlist_status'] | null;
				};
				Update: {
					admin_notes?: string | null;
					age?: never;
					current_position?: never;
					date_of_birth?: string | null;
					email?: string | null;
					first_name?: string | null;
					full_name?: never;
					id?: string | null;
					initial_registration_date?: string | null;
					insurance_form_submitted?: boolean | null;
					last_contacted?: string | null;
					last_name?: string | null;
					last_status_change?: string | null;
					medical_conditions?: string | null;
					never_invited?: never;
					phone_number?: string | null;
					status?: Database['public']['Enums']['waitlist_status'] | null;
				};
				Relationships: [];
			};
		};
		Functions: {
			custom_access_token_hook: {
				Args: {
					event: Json;
				};
				Returns: Json;
			};
			get_current_user_with_profile: {
				Args: Record<PropertyKey, never>;
				Returns: Json;
			};
			get_waitlist_position: {
				Args: {
					p_waitlist_id: string;
				};
				Returns: number;
			};
			has_any_role: {
				Args: {
					uid: string;
					required_roles: Database['public']['Enums']['role_type'][];
				};
				Returns: boolean;
			};
			has_role: {
				Args: {
					uid: string;
					required_role: Database['public']['Enums']['role_type'];
				};
				Returns: boolean;
			};
			update_waitlist_status: {
				Args: {
					p_waitlist_id: string;
					p_new_status: Database['public']['Enums']['waitlist_status'];
					p_notes?: string;
				};
				Returns: undefined;
			};
		};
		Enums: {
			role_type:
				| 'admin'
				| 'president'
				| 'treasurer'
				| 'committee_coordinator'
				| 'sparring_coordinator'
				| 'workshop_coordinator'
				| 'beginners_coordinator'
				| 'quartermaster'
				| 'pr_manager'
				| 'volunteer_coordinator'
				| 'research_coordinator'
				| 'coach'
				| 'member';
			waitlist_status:
				| 'waiting'
				| 'invited'
				| 'paid'
				| 'deferred'
				| 'cancelled'
				| 'completed'
				| 'no_reply';
		};
		CompositeTypes: {
			[_ in never]: never;
		};
	};
};

type PublicSchema = Database[Extract<keyof Database, 'public'>];

export type Tables<
	PublicTableNameOrOptions extends
		| keyof (PublicSchema['Tables'] & PublicSchema['Views'])
		| { schema: keyof Database },
	TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
		? keyof (Database[PublicTableNameOrOptions['schema']]['Tables'] &
				Database[PublicTableNameOrOptions['schema']]['Views'])
		: never = never
> = PublicTableNameOrOptions extends { schema: keyof Database }
	? (Database[PublicTableNameOrOptions['schema']]['Tables'] &
			Database[PublicTableNameOrOptions['schema']]['Views'])[TableName] extends {
			Row: infer R;
		}
		? R
		: never
	: PublicTableNameOrOptions extends keyof (PublicSchema['Tables'] & PublicSchema['Views'])
		? (PublicSchema['Tables'] & PublicSchema['Views'])[PublicTableNameOrOptions] extends {
				Row: infer R;
			}
			? R
			: never
		: never;

export type TablesInsert<
	PublicTableNameOrOptions extends keyof PublicSchema['Tables'] | { schema: keyof Database },
	TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
		? keyof Database[PublicTableNameOrOptions['schema']]['Tables']
		: never = never
> = PublicTableNameOrOptions extends { schema: keyof Database }
	? Database[PublicTableNameOrOptions['schema']]['Tables'][TableName] extends {
			Insert: infer I;
		}
		? I
		: never
	: PublicTableNameOrOptions extends keyof PublicSchema['Tables']
		? PublicSchema['Tables'][PublicTableNameOrOptions] extends {
				Insert: infer I;
			}
			? I
			: never
		: never;

export type TablesUpdate<
	PublicTableNameOrOptions extends keyof PublicSchema['Tables'] | { schema: keyof Database },
	TableName extends PublicTableNameOrOptions extends { schema: keyof Database }
		? keyof Database[PublicTableNameOrOptions['schema']]['Tables']
		: never = never
> = PublicTableNameOrOptions extends { schema: keyof Database }
	? Database[PublicTableNameOrOptions['schema']]['Tables'][TableName] extends {
			Update: infer U;
		}
		? U
		: never
	: PublicTableNameOrOptions extends keyof PublicSchema['Tables']
		? PublicSchema['Tables'][PublicTableNameOrOptions] extends {
				Update: infer U;
			}
			? U
			: never
		: never;

export type Enums<
	PublicEnumNameOrOptions extends keyof PublicSchema['Enums'] | { schema: keyof Database },
	EnumName extends PublicEnumNameOrOptions extends { schema: keyof Database }
		? keyof Database[PublicEnumNameOrOptions['schema']]['Enums']
		: never = never
> = PublicEnumNameOrOptions extends { schema: keyof Database }
	? Database[PublicEnumNameOrOptions['schema']]['Enums'][EnumName]
	: PublicEnumNameOrOptions extends keyof PublicSchema['Enums']
		? PublicSchema['Enums'][PublicEnumNameOrOptions]
		: never;

export type CompositeTypes<
	PublicCompositeTypeNameOrOptions extends
		| keyof PublicSchema['CompositeTypes']
		| { schema: keyof Database },
	CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
		schema: keyof Database;
	}
		? keyof Database[PublicCompositeTypeNameOrOptions['schema']]['CompositeTypes']
		: never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof Database }
	? Database[PublicCompositeTypeNameOrOptions['schema']]['CompositeTypes'][CompositeTypeName]
	: PublicCompositeTypeNameOrOptions extends keyof PublicSchema['CompositeTypes']
		? PublicSchema['CompositeTypes'][PublicCompositeTypeNameOrOptions]
		: never;
