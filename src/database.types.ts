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
					last_login: string | null;
					last_name: string;
					updated_at: string | null;
				};
				Insert: {
					created_at?: string | null;
					first_name: string;
					id: string;
					is_active?: boolean | null;
					last_login?: string | null;
					last_name: string;
					updated_at?: string | null;
				};
				Update: {
					created_at?: string | null;
					first_name?: string;
					id?: string;
					is_active?: boolean | null;
					last_login?: string | null;
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
		};
		Views: {
			[_ in never]: never;
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
				| 'member';
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
