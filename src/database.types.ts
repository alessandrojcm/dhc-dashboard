export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          operationName?: string
          query?: string
          variables?: Json
          extensions?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      club_activities: {
        Row: {
          announce_discord: boolean | null
          announce_email: boolean | null
          created_at: string | null
          created_by: string | null
          description: string | null
          end_date: string
          id: string
          is_public: boolean | null
          location: string
          max_capacity: number
          price_member: number
          price_non_member: number
          refund_days: number | null
          start_date: string
          status: Database["public"]["Enums"]["club_activity_status"] | null
          title: string
          updated_at: string | null
        }
        Insert: {
          announce_discord?: boolean | null
          announce_email?: boolean | null
          created_at?: string | null
          created_by?: string | null
          description?: string | null
          end_date: string
          id?: string
          is_public?: boolean | null
          location: string
          max_capacity: number
          price_member: number
          price_non_member: number
          refund_days?: number | null
          start_date: string
          status?: Database["public"]["Enums"]["club_activity_status"] | null
          title: string
          updated_at?: string | null
        }
        Update: {
          announce_discord?: boolean | null
          announce_email?: boolean | null
          created_at?: string | null
          created_by?: string | null
          description?: string | null
          end_date?: string
          id?: string
          is_public?: boolean | null
          location?: string
          max_capacity?: number
          price_member?: number
          price_non_member?: number
          refund_days?: number | null
          start_date?: string
          status?: Database["public"]["Enums"]["club_activity_status"] | null
          title?: string
          updated_at?: string | null
        }
        Relationships: []
      }
      club_activity_interest: {
        Row: {
          club_activity_id: string
          created_at: string | null
          id: string
          updated_at: string | null
          user_id: string
        }
        Insert: {
          club_activity_id: string
          created_at?: string | null
          id?: string
          updated_at?: string | null
          user_id: string
        }
        Update: {
          club_activity_id?: string
          created_at?: string | null
          id?: string
          updated_at?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "club_activity_interest_club_activity_id_fkey"
            columns: ["club_activity_id"]
            isOneToOne: false
            referencedRelation: "club_activities"
            referencedColumns: ["id"]
          },
        ]
      }
      club_activity_refunds: {
        Row: {
          completed_at: string | null
          created_at: string | null
          id: string
          processed_at: string | null
          processed_by: string | null
          refund_amount: number
          refund_reason: string | null
          registration_id: string
          requested_at: string
          requested_by: string | null
          status: Database["public"]["Enums"]["refund_status"]
          stripe_payment_intent_id: string | null
          stripe_refund_id: string | null
          updated_at: string | null
        }
        Insert: {
          completed_at?: string | null
          created_at?: string | null
          id?: string
          processed_at?: string | null
          processed_by?: string | null
          refund_amount: number
          refund_reason?: string | null
          registration_id: string
          requested_at?: string
          requested_by?: string | null
          status?: Database["public"]["Enums"]["refund_status"]
          stripe_payment_intent_id?: string | null
          stripe_refund_id?: string | null
          updated_at?: string | null
        }
        Update: {
          completed_at?: string | null
          created_at?: string | null
          id?: string
          processed_at?: string | null
          processed_by?: string | null
          refund_amount?: number
          refund_reason?: string | null
          registration_id?: string
          requested_at?: string
          requested_by?: string | null
          status?: Database["public"]["Enums"]["refund_status"]
          stripe_payment_intent_id?: string | null
          stripe_refund_id?: string | null
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "club_activity_refunds_registration_id_fkey"
            columns: ["registration_id"]
            isOneToOne: true
            referencedRelation: "club_activity_registrations"
            referencedColumns: ["id"]
          },
        ]
      }
      club_activity_registrations: {
        Row: {
          amount_paid: number
          attendance_marked_at: string | null
          attendance_marked_by: string | null
          attendance_notes: string | null
          attendance_status: string | null
          cancelled_at: string | null
          club_activity_id: string
          confirmed_at: string | null
          created_at: string | null
          currency: string
          external_user_id: string | null
          id: string
          member_user_id: string | null
          registered_at: string | null
          registration_notes: string | null
          status: Database["public"]["Enums"]["registration_status"]
          stripe_checkout_session_id: string | null
          updated_at: string | null
        }
        Insert: {
          amount_paid: number
          attendance_marked_at?: string | null
          attendance_marked_by?: string | null
          attendance_notes?: string | null
          attendance_status?: string | null
          cancelled_at?: string | null
          club_activity_id: string
          confirmed_at?: string | null
          created_at?: string | null
          currency?: string
          external_user_id?: string | null
          id?: string
          member_user_id?: string | null
          registered_at?: string | null
          registration_notes?: string | null
          status?: Database["public"]["Enums"]["registration_status"]
          stripe_checkout_session_id?: string | null
          updated_at?: string | null
        }
        Update: {
          amount_paid?: number
          attendance_marked_at?: string | null
          attendance_marked_by?: string | null
          attendance_notes?: string | null
          attendance_status?: string | null
          cancelled_at?: string | null
          club_activity_id?: string
          confirmed_at?: string | null
          created_at?: string | null
          currency?: string
          external_user_id?: string | null
          id?: string
          member_user_id?: string | null
          registered_at?: string | null
          registration_notes?: string | null
          status?: Database["public"]["Enums"]["registration_status"]
          stripe_checkout_session_id?: string | null
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "club_activity_registrations_club_activity_id_fkey"
            columns: ["club_activity_id"]
            isOneToOne: false
            referencedRelation: "club_activities"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "club_activity_registrations_external_user_id_fkey"
            columns: ["external_user_id"]
            isOneToOne: false
            referencedRelation: "external_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "club_activity_registrations_member_user_id_fkey"
            columns: ["member_user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["supabase_user_id"]
          },
        ]
      }
      external_users: {
        Row: {
          created_at: string | null
          email: string
          first_name: string
          id: string
          last_name: string
          phone_number: string | null
          updated_at: string | null
        }
        Insert: {
          created_at?: string | null
          email: string
          first_name: string
          id?: string
          last_name: string
          phone_number?: string | null
          updated_at?: string | null
        }
        Update: {
          created_at?: string | null
          email?: string
          first_name?: string
          id?: string
          last_name?: string
          phone_number?: string | null
          updated_at?: string | null
        }
        Relationships: []
      }
      invitation_processing_logs: {
        Row: {
          created_at: string
          failure_count: number
          id: string
          results: Json
          success_count: number
          total_count: number
          user_id: string
        }
        Insert: {
          created_at?: string
          failure_count: number
          id?: string
          results: Json
          success_count: number
          total_count: number
          user_id: string
        }
        Update: {
          created_at?: string
          failure_count?: number
          id?: string
          results?: Json
          success_count?: number
          total_count?: number
          user_id?: string
        }
        Relationships: []
      }
      invitations: {
        Row: {
          created_at: string
          created_by: string | null
          email: string
          expires_at: string
          id: string
          invitation_type: string
          metadata: Json | null
          status: Database["public"]["Enums"]["invitation_status"]
          updated_at: string
          user_id: string | null
          waitlist_id: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          email: string
          expires_at?: string
          id?: string
          invitation_type: string
          metadata?: Json | null
          status?: Database["public"]["Enums"]["invitation_status"]
          updated_at?: string
          user_id?: string | null
          waitlist_id?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          email?: string
          expires_at?: string
          id?: string
          invitation_type?: string
          metadata?: Json | null
          status?: Database["public"]["Enums"]["invitation_status"]
          updated_at?: string
          user_id?: string | null
          waitlist_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invitations_waitlist_id_fkey"
            columns: ["waitlist_id"]
            isOneToOne: false
            referencedRelation: "member_management_view"
            referencedColumns: ["from_waitlist_id"]
          },
          {
            foreignKeyName: "invitations_waitlist_id_fkey"
            columns: ["waitlist_id"]
            isOneToOne: false
            referencedRelation: "waitlist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_waitlist_id_fkey"
            columns: ["waitlist_id"]
            isOneToOne: false
            referencedRelation: "waitlist_management_view"
            referencedColumns: ["id"]
          },
        ]
      }
      member_profiles: {
        Row: {
          additional_data: Json | null
          created_at: string | null
          id: string
          insurance_form_submitted: boolean
          last_payment_date: string | null
          membership_end_date: string | null
          membership_start_date: string | null
          next_of_kin_name: string
          next_of_kin_phone: string
          preferred_weapon: Database["public"]["Enums"]["preferred_weapon"][]
          updated_at: string | null
          user_profile_id: string
        }
        Insert: {
          additional_data?: Json | null
          created_at?: string | null
          id: string
          insurance_form_submitted?: boolean
          last_payment_date?: string | null
          membership_end_date?: string | null
          membership_start_date?: string | null
          next_of_kin_name: string
          next_of_kin_phone: string
          preferred_weapon: Database["public"]["Enums"]["preferred_weapon"][]
          updated_at?: string | null
          user_profile_id: string
        }
        Update: {
          additional_data?: Json | null
          created_at?: string | null
          id?: string
          insurance_form_submitted?: boolean
          last_payment_date?: string | null
          membership_end_date?: string | null
          membership_start_date?: string | null
          next_of_kin_name?: string
          next_of_kin_phone?: string
          preferred_weapon?: Database["public"]["Enums"]["preferred_weapon"][]
          updated_at?: string | null
          user_profile_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_user_profile"
            columns: ["user_profile_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_profiles_user_profile_id_fkey"
            columns: ["user_profile_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      notifications: {
        Row: {
          body: string
          created_at: string
          id: string
          read_at: string | null
          user_id: string
        }
        Insert: {
          body: string
          created_at?: string
          id?: string
          read_at?: string | null
          user_id: string
        }
        Update: {
          body?: string
          created_at?: string
          id?: string
          read_at?: string | null
          user_id?: string
        }
        Relationships: []
      }
      settings: {
        Row: {
          created_at: string | null
          description: string | null
          id: string
          key: string
          type: Database["public"]["Enums"]["setting_type"]
          updated_at: string | null
          updated_by: string | null
          value: string
        }
        Insert: {
          created_at?: string | null
          description?: string | null
          id?: string
          key: string
          type: Database["public"]["Enums"]["setting_type"]
          updated_at?: string | null
          updated_by?: string | null
          value: string
        }
        Update: {
          created_at?: string | null
          description?: string | null
          id?: string
          key?: string
          type?: Database["public"]["Enums"]["setting_type"]
          updated_at?: string | null
          updated_by?: string | null
          value?: string
        }
        Relationships: []
      }
      user_audit_log: {
        Row: {
          action: string
          created_at: string | null
          details: Json | null
          id: string
          ip_address: string | null
          user_id: string | null
        }
        Insert: {
          action: string
          created_at?: string | null
          details?: Json | null
          id?: string
          ip_address?: string | null
          user_id?: string | null
        }
        Update: {
          action?: string
          created_at?: string | null
          details?: Json | null
          id?: string
          ip_address?: string | null
          user_id?: string | null
        }
        Relationships: []
      }
      user_profiles: {
        Row: {
          created_at: string | null
          customer_id: string | null
          date_of_birth: string
          first_name: string
          gender: Database["public"]["Enums"]["gender"] | null
          id: string
          is_active: boolean | null
          last_name: string
          medical_conditions: string | null
          phone_number: string
          pronouns: string | null
          search_text: unknown | null
          social_media_consent:
            | Database["public"]["Enums"]["social_media_consent"]
            | null
          supabase_user_id: string | null
          updated_at: string | null
          waitlist_id: string | null
        }
        Insert: {
          created_at?: string | null
          customer_id?: string | null
          date_of_birth: string
          first_name: string
          gender?: Database["public"]["Enums"]["gender"] | null
          id?: string
          is_active?: boolean | null
          last_name: string
          medical_conditions?: string | null
          phone_number?: string
          pronouns?: string | null
          search_text?: unknown | null
          social_media_consent?:
            | Database["public"]["Enums"]["social_media_consent"]
            | null
          supabase_user_id?: string | null
          updated_at?: string | null
          waitlist_id?: string | null
        }
        Update: {
          created_at?: string | null
          customer_id?: string | null
          date_of_birth?: string
          first_name?: string
          gender?: Database["public"]["Enums"]["gender"] | null
          id?: string
          is_active?: boolean | null
          last_name?: string
          medical_conditions?: string | null
          phone_number?: string
          pronouns?: string | null
          search_text?: unknown | null
          social_media_consent?:
            | Database["public"]["Enums"]["social_media_consent"]
            | null
          supabase_user_id?: string | null
          updated_at?: string | null
          waitlist_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_waitlist_id"
            columns: ["waitlist_id"]
            isOneToOne: false
            referencedRelation: "member_management_view"
            referencedColumns: ["from_waitlist_id"]
          },
          {
            foreignKeyName: "fk_waitlist_id"
            columns: ["waitlist_id"]
            isOneToOne: false
            referencedRelation: "waitlist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fk_waitlist_id"
            columns: ["waitlist_id"]
            isOneToOne: false
            referencedRelation: "waitlist_management_view"
            referencedColumns: ["id"]
          },
        ]
      }
      user_roles: {
        Row: {
          id: number
          role: Database["public"]["Enums"]["role_type"]
          user_id: string
        }
        Insert: {
          id?: number
          role: Database["public"]["Enums"]["role_type"]
          user_id: string
        }
        Update: {
          id?: number
          role?: Database["public"]["Enums"]["role_type"]
          user_id?: string
        }
        Relationships: []
      }
      waitlist: {
        Row: {
          admin_notes: string | null
          email: string
          id: string
          initial_registration_date: string | null
          insurance_form_submitted: boolean | null
          last_contacted: string | null
          last_status_change: string | null
          status: Database["public"]["Enums"]["waitlist_status"]
        }
        Insert: {
          admin_notes?: string | null
          email: string
          id?: string
          initial_registration_date?: string | null
          insurance_form_submitted?: boolean | null
          last_contacted?: string | null
          last_status_change?: string | null
          status?: Database["public"]["Enums"]["waitlist_status"]
        }
        Update: {
          admin_notes?: string | null
          email?: string
          id?: string
          initial_registration_date?: string | null
          insurance_form_submitted?: boolean | null
          last_contacted?: string | null
          last_status_change?: string | null
          status?: Database["public"]["Enums"]["waitlist_status"]
        }
        Relationships: []
      }
      waitlist_guardians: {
        Row: {
          created_at: string | null
          first_name: string
          id: string
          last_name: string
          phone_number: string
          profile_id: string
        }
        Insert: {
          created_at?: string | null
          first_name: string
          id?: string
          last_name: string
          phone_number: string
          profile_id: string
        }
        Update: {
          created_at?: string | null
          first_name?: string
          id?: string
          last_name?: string
          phone_number?: string
          profile_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "waitlist_guardians_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      waitlist_status_history: {
        Row: {
          changed_at: string | null
          changed_by: string | null
          id: string
          new_status: Database["public"]["Enums"]["waitlist_status"]
          notes: string | null
          old_status: Database["public"]["Enums"]["waitlist_status"] | null
          waitlist_id: string | null
        }
        Insert: {
          changed_at?: string | null
          changed_by?: string | null
          id?: string
          new_status: Database["public"]["Enums"]["waitlist_status"]
          notes?: string | null
          old_status?: Database["public"]["Enums"]["waitlist_status"] | null
          waitlist_id?: string | null
        }
        Update: {
          changed_at?: string | null
          changed_by?: string | null
          id?: string
          new_status?: Database["public"]["Enums"]["waitlist_status"]
          notes?: string | null
          old_status?: Database["public"]["Enums"]["waitlist_status"] | null
          waitlist_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "waitlist_status_history_waitlist_id_fkey"
            columns: ["waitlist_id"]
            isOneToOne: false
            referencedRelation: "member_management_view"
            referencedColumns: ["from_waitlist_id"]
          },
          {
            foreignKeyName: "waitlist_status_history_waitlist_id_fkey"
            columns: ["waitlist_id"]
            isOneToOne: false
            referencedRelation: "waitlist"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "waitlist_status_history_waitlist_id_fkey"
            columns: ["waitlist_id"]
            isOneToOne: false
            referencedRelation: "waitlist_management_view"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      club_activity_interest_counts: {
        Row: {
          club_activity_id: string | null
          interest_count: number | null
        }
        Relationships: [
          {
            foreignKeyName: "club_activity_interest_club_activity_id_fkey"
            columns: ["club_activity_id"]
            isOneToOne: false
            referencedRelation: "club_activities"
            referencedColumns: ["id"]
          },
        ]
      }
      member_management_view: {
        Row: {
          additional_data: Json | null
          age: number | null
          created_at: string | null
          email: string | null
          first_name: string | null
          from_waitlist_id: string | null
          gender: Database["public"]["Enums"]["gender"] | null
          guardian_first_name: string | null
          guardian_last_name: string | null
          guardian_phone_number: string | null
          id: string | null
          insurance_form_submitted: boolean | null
          is_active: boolean | null
          last_name: string | null
          last_payment_date: string | null
          medical_conditions: string | null
          membership_end_date: string | null
          membership_start_date: string | null
          next_of_kin_name: string | null
          next_of_kin_phone: string | null
          phone_number: string | null
          preferred_weapon:
            | Database["public"]["Enums"]["preferred_weapon"][]
            | null
          pronouns: string | null
          roles: Database["public"]["Enums"]["role_type"][] | null
          search_text: unknown | null
          social_media_consent:
            | Database["public"]["Enums"]["social_media_consent"]
            | null
          updated_at: string | null
          user_profile_id: string | null
          waitlist_registration_date: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_user_profile"
            columns: ["user_profile_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_profiles_user_profile_id_fkey"
            columns: ["user_profile_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      waitlist_management_view: {
        Row: {
          admin_notes: string | null
          age: number | null
          current_position: number | null
          email: string | null
          full_name: string | null
          guardian_first_name: string | null
          guardian_last_name: string | null
          guardian_phone_number: string | null
          id: string | null
          initial_registration_date: string | null
          insurance_form_submitted: boolean | null
          last_contacted: string | null
          last_status_change: string | null
          medical_conditions: string | null
          phone_number: string | null
          search_text: unknown | null
          social_media_consent:
            | Database["public"]["Enums"]["social_media_consent"]
            | null
          status: Database["public"]["Enums"]["waitlist_status"] | null
        }
        Relationships: []
      }
    }
    Functions: {
      add_workshop_announcement: {
        Args: { workshop_id: string; announcement_type: string }
        Returns: undefined
      }
      calculate_refund_amount: {
        Args: { registration_id: string }
        Returns: number
      }
      check_refund_eligibility: {
        Args: { registration_id: string }
        Returns: boolean
      }
      check_workshop_capacity: {
        Args: { activity_id: string }
        Returns: boolean
      }
      complete_member_registration: {
        Args: {
          v_user_id: string
          p_next_of_kin_name: string
          p_next_of_kin_phone: string
          p_insurance_form_submitted: boolean
        }
        Returns: string
      }
      create_invitation: {
        Args: {
          v_user_id: string
          p_email: string
          p_first_name: string
          p_last_name: string
          p_date_of_birth: string
          p_phone_number: string
          p_invitation_type: string
          p_waitlist_id?: string
          p_expires_at?: string
          p_metadata?: Json
        }
        Returns: string
      }
      custom_access_token_hook: {
        Args: { event: Json }
        Returns: Json
      }
      get_conversion_metrics: {
        Args: { start_date: string; end_date: string }
        Returns: {
          cohort_date: string
          total_signups: number
          workshop_completions: number
          club_joins: number
          workshop_conversion_rate: number
          join_conversion_rate: number
          avg_time_to_join: unknown
        }[]
      }
      get_current_user_with_profile: {
        Args: Record<PropertyKey, never>
        Returns: Json
      }
      get_email_from_auth_users: {
        Args: { user_id: string }
        Returns: {
          email: string
        }[]
      }
      get_gender_options: {
        Args: Record<PropertyKey, never>
        Returns: Json
      }
      get_invitation_info: {
        Args: { p_invitation_id: string }
        Returns: Json
      }
      get_member_data: {
        Args: { user_uuid: string }
        Returns: Database["public"]["CompositeTypes"]["member_data_type"]
      }
      get_membership_info: {
        Args: { uid: string }
        Returns: Json
      }
      get_waitlist_position: {
        Args: { p_waitlist_id: string }
        Returns: number
      }
      get_weapons_options: {
        Args: Record<PropertyKey, never>
        Returns: Json
      }
      has_any_role: {
        Args: {
          uid: string
          required_roles: Database["public"]["Enums"]["role_type"][]
        }
        Returns: boolean
      }
      has_role: {
        Args: {
          uid: string
          required_role: Database["public"]["Enums"]["role_type"]
        }
        Returns: boolean
      }
      insert_waitlist_entry: {
        Args: {
          first_name: string
          last_name: string
          email: string
          date_of_birth: string
          phone_number: string
          pronouns: string
          gender: Database["public"]["Enums"]["gender"]
          medical_conditions: string
          social_media_consent?: Database["public"]["Enums"]["social_media_consent"]
        }
        Returns: {
          profile_id: string
          waitlist_id: string
          user_first_name: string
          user_last_name: string
          user_email: string
          user_date_of_birth: string
          user_phone_number: string
          user_pronouns: string
          user_gender: Database["public"]["Enums"]["gender"]
          user_medical_conditions: string
          user_social_media_consent: Database["public"]["Enums"]["social_media_consent"]
        }[]
      }
      mark_expired_invitations: {
        Args: Record<PropertyKey, never>
        Returns: number
      }
      mark_notification_as_read: {
        Args: { notification_id: string }
        Returns: undefined
      }
      process_workshop_announcements: {
        Args: Record<PropertyKey, never>
        Returns: undefined
      }
      register_for_workshop_checkout: {
        Args: {
          p_activity_id: string
          p_amount_paid: number
          p_stripe_checkout_session_id: string
          p_member_user_id?: string
          p_external_user_data?: Json
        }
        Returns: string
      }
      update_invitation_status: {
        Args: {
          p_invitation_id: string
          p_status: Database["public"]["Enums"]["invitation_status"]
        }
        Returns: boolean
      }
      update_member_data: {
        Args: {
          user_uuid: string
          p_first_name?: string
          p_last_name?: string
          p_is_active?: boolean
          p_medical_conditions?: string
          p_phone_number?: string
          p_gender?: Database["public"]["Enums"]["gender"]
          p_pronouns?: string
          p_date_of_birth?: string
          p_next_of_kin_name?: string
          p_next_of_kin_phone?: string
          p_preferred_weapon?: Database["public"]["Enums"]["preferred_weapon"][]
          p_membership_start_date?: string
          p_membership_end_date?: string
          p_last_payment_date?: string
          p_insurance_form_submitted?: boolean
          p_additional_data?: Json
          p_social_media_consent?: Database["public"]["Enums"]["social_media_consent"]
        }
        Returns: Database["public"]["CompositeTypes"]["member_data_type"]
      }
      update_member_payment: {
        Args: { p_user_id: string; p_payment_date?: string }
        Returns: undefined
      }
      update_waitlist_status: {
        Args: {
          p_waitlist_id: string
          p_new_status: Database["public"]["Enums"]["waitlist_status"]
          p_notes?: string
        }
        Returns: undefined
      }
    }
    Enums: {
      club_activity_status: "planned" | "published" | "finished" | "cancelled"
      gender:
        | "man (cis)"
        | "woman (cis)"
        | "non-binary"
        | "man (trans)"
        | "woman (trans)"
        | "other"
      invitation_status: "pending" | "accepted" | "expired" | "revoked"
      preferred_weapon: "longsword" | "sword_and_buckler"
      refund_status:
        | "pending"
        | "processing"
        | "completed"
        | "failed"
        | "cancelled"
      registration_status: "pending" | "confirmed" | "cancelled" | "refunded"
      role_type:
        | "admin"
        | "president"
        | "treasurer"
        | "committee_coordinator"
        | "sparring_coordinator"
        | "workshop_coordinator"
        | "beginners_coordinator"
        | "quartermaster"
        | "pr_manager"
        | "volunteer_coordinator"
        | "research_coordinator"
        | "coach"
        | "member"
      setting_type: "text" | "boolean"
      social_media_consent: "no" | "yes_recognizable" | "yes_unrecognizable"
      waitlist_status:
        | "waiting"
        | "invited"
        | "paid"
        | "deferred"
        | "cancelled"
        | "completed"
        | "no_reply"
        | "joined"
    }
    CompositeTypes: {
      member_data_type: {
        first_name: string | null
        last_name: string | null
        is_active: boolean | null
        medical_conditions: string | null
        phone_number: string | null
        gender: string | null
        pronouns: string | null
        date_of_birth: string | null
        next_of_kin_name: string | null
        next_of_kin_phone: string | null
        preferred_weapon:
          | Database["public"]["Enums"]["preferred_weapon"][]
          | null
        membership_start_date: string | null
        membership_end_date: string | null
        last_payment_date: string | null
        insurance_form_submitted: boolean | null
        additional_data: Json | null
        social_media_consent:
          | Database["public"]["Enums"]["social_media_consent"]
          | null
      }
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      club_activity_status: ["planned", "published", "finished", "cancelled"],
      gender: [
        "man (cis)",
        "woman (cis)",
        "non-binary",
        "man (trans)",
        "woman (trans)",
        "other",
      ],
      invitation_status: ["pending", "accepted", "expired", "revoked"],
      preferred_weapon: ["longsword", "sword_and_buckler"],
      refund_status: [
        "pending",
        "processing",
        "completed",
        "failed",
        "cancelled",
      ],
      registration_status: ["pending", "confirmed", "cancelled", "refunded"],
      role_type: [
        "admin",
        "president",
        "treasurer",
        "committee_coordinator",
        "sparring_coordinator",
        "workshop_coordinator",
        "beginners_coordinator",
        "quartermaster",
        "pr_manager",
        "volunteer_coordinator",
        "research_coordinator",
        "coach",
        "member",
      ],
      setting_type: ["text", "boolean"],
      social_media_consent: ["no", "yes_recognizable", "yes_unrecognizable"],
      waitlist_status: [
        "waiting",
        "invited",
        "paid",
        "deferred",
        "cancelled",
        "completed",
        "no_reply",
        "joined",
      ],
    },
  },
} as const

