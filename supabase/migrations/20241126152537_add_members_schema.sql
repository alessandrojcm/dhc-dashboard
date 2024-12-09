-- Create weapon preference enum
CREATE TYPE public.preferred_weapon AS ENUM (
    'longsword',
    'sword_and_buckler'
    );

-- Create members table
CREATE TABLE public.member_profiles
(
    id                    UUID PRIMARY KEY references auth.users (id),
    user_profile_id       UUID                    NOT NULL REFERENCES public.user_profiles (id),
    -- Next of kin information
    next_of_kin_name      TEXT                    NOT NULL,
    next_of_kin_phone     TEXT                    NOT NULL,
    -- Member preferences and status
    preferred_weapon      public.preferred_weapon[] NOT NULL,
    membership_start_date TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    membership_end_date   TIMESTAMP WITH TIME ZONE,
    last_payment_date     TIMESTAMP WITH TIME ZONE,
    insurance_form_submitted BOOLEAN DEFAULT FALSE NOT NULL,
    -- Additional dynamic data
    additional_data       JSONB                    DEFAULT '{}'::jsonb,
    -- Metadata
    created_at            TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at            TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    -- Constraints
    CONSTRAINT fk_user_profile
        FOREIGN KEY (user_profile_id)
            REFERENCES public.user_profiles (id)
            ON DELETE CASCADE
);

-- Indexes
CREATE INDEX idx_member_profiles_user_id ON public.member_profiles (user_profile_id);

-- Function to complete member registration
CREATE OR REPLACE FUNCTION public.complete_member_registration(
    p_user_profile_id UUID,
    p_next_of_kin_name TEXT,
    p_next_of_kin_phone TEXT,
    p_insurance_form_submitted BOOLEAN
) RETURNS UUID
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS
$$
DECLARE
    v_member_id UUID;
    v_user_id   UUID;
BEGIN
    -- Get user ID
    SELECT supabase_user_id
    INTO v_user_id
    FROM public.user_profiles
    WHERE id = p_user_profile_id;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User profile not found';
    END IF;

    IF p_insurance_form_submitted IS FALSE THEN
        RAISE EXCEPTION 'You must submit the insurance form';
    END IF;

    -- Create member profile
    INSERT INTO public.member_profiles (id,
                                        user_profile_id,
                                        next_of_kin_name,
                                        next_of_kin_phone,
                                        preferred_weapon,
                                        insurance_form_submitted
                                        )
    VALUES (v_user_id,
            p_user_profile_id,
            p_next_of_kin_name,
            p_next_of_kin_phone,
            ARRAY []::public.preferred_weapon[],
            p_insurance_form_submitted)
    RETURNING id INTO v_member_id;

    UPDATE public.user_profiles
    SET is_active = true
    WHERE id = p_user_profile_id;

    -- Add member role
    INSERT INTO public.user_roles (user_id, role)
    VALUES (v_user_id, 'member'::public.role_type);

    RETURN v_member_id;
END;
$$;

-- Function to update member payment status
CREATE OR REPLACE FUNCTION public.update_member_payment(
    p_user_id UUID,
    p_payment_date TIMESTAMP WITH TIME ZONE DEFAULT NOW()
) RETURNS VOID
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS
$$
BEGIN
    -- Update member profile payment date
    UPDATE public.member_profiles
    SET last_payment_date = p_payment_date
    WHERE id = p_user_id;

    -- Update user_profiles active status
    UPDATE public.user_profiles
    SET is_active = true
    WHERE supabase_user_id = p_user_id;
END;
$$;

-- Triggers for updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path = ''
AS
$$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER update_member_profiles_updated_at
    BEFORE UPDATE
    ON public.member_profiles
    FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- RLS Policies
ALTER TABLE public.member_profiles
    ENABLE ROW LEVEL SECURITY;

-- Member profiles policies
CREATE POLICY "Members can view their own profile"
    ON public.member_profiles FOR SELECT
    TO authenticated
    USING (
        (select auth.uid()) = public.member_profiles.id
    );

CREATE POLICY "Committee members can view all profiles"
    ON public.member_profiles FOR SELECT
    TO authenticated
    USING (
    (SELECT public.has_any_role(
                    (SELECT auth.uid()),
                    ARRAY ['admin', 'president', 'treasurer', 'committee_coordinator', 'sparring_coordinator', 'workshop_coordinator', 'beginners_coordinator', 'quartermaster', 'pr_manager', 'volunteer_coordinator', 'research_coordinator', 'coach']::public.role_type[]
            ))
    );

CREATE POLICY "Committee members can modify profiles"
    ON public.member_profiles FOR UPDATE
    TO authenticated
    USING (
    (SELECT public.has_any_role(
                    (SELECT auth.uid()),
                    ARRAY ['admin', 'president', 'treasurer', 'committee_coordinator']::public.role_type[]
            ))
    );

CREATE POLICY "Users can edit their own profile"
    ON public.member_profiles FOR UPDATE
    TO authenticated
    USING (
        (select auth.uid()) = public.member_profiles.id
    );

-- Helper view for member management
CREATE OR REPLACE VIEW public.member_management_view AS
WITH current_user_id AS (SELECT auth.uid() as uid)
SELECT mp.*,
       up.first_name,
       up.last_name,
       up.phone_number,
       up.gender,
       up.pronouns,
       up.is_active,
       au.email,
       w.id                        as from_waitlist_id,
       w.initial_registration_date as waitlist_registration_date,
       array_agg(ur.role)          as roles,
       extract(year from age(up.date_of_birth)) as age,
       up.search_text                           as search_text
FROM public.member_profiles mp
         JOIN public.user_profiles up ON mp.user_profile_id = up.id
         JOIN auth.users au ON up.supabase_user_id = au.id
         LEFT JOIN public.waitlist w ON up.waitlist_id = w.id
         LEFT JOIN public.user_roles ur ON up.supabase_user_id = ur.user_id
GROUP BY mp.id, up.id, au.id, w.id;

-- Grant necessary permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON public.member_profiles TO authenticated;
