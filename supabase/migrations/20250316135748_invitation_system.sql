-- Create invitation_status enum
CREATE TYPE public.invitation_status AS ENUM (
  'pending',
  'accepted',
  'expired',
  'revoked'
);

-- Create invitations table
CREATE TABLE public.invitations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email TEXT NOT NULL,
  user_id UUID REFERENCES auth.users(id),
  waitlist_id UUID REFERENCES public.waitlist(id),
  status public.invitation_status NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days'),
  created_by UUID REFERENCES auth.users(id),
  invitation_type TEXT NOT NULL, -- 'workshop' or 'admin'
  metadata JSONB,
  
  CONSTRAINT invitations_email_status_unique UNIQUE (email, status)
);

-- Add RLS policies
ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;

-- Allow admins to see all invitations
CREATE POLICY "Admins can see all invitations" 
  ON public.invitations FOR SELECT 
  USING (public.has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::role_type[]));

-- Allow admins to create/update invitations
CREATE POLICY "Admins can create and update invitations" 
  ON public.invitations FOR ALL 
  USING (public.has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::role_type[]));

-- Allow users to see their own invitations
CREATE POLICY "Users can see their own invitations" 
  ON public.invitations FOR SELECT 
  USING ((select auth.uid()) = user_id);

-- Create function to generate invitation
CREATE OR REPLACE FUNCTION public.create_invitation(
  p_email TEXT,
  p_invitation_type TEXT,
  p_waitlist_id UUID DEFAULT NULL,
  p_expires_at TIMESTAMPTZ DEFAULT (now() + interval '7 days'),
  p_metadata JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id UUID;
  v_invitation_id UUID;
BEGIN
  -- Check if caller has admin role
  IF NOT public.has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::role_type[]) THEN
    RAISE EXCEPTION USING
      errcode = 'PERM1',
      message = 'Permission denied: Admin role required to create invitations';
  END IF;

  -- Check if user exists
  SELECT id INTO v_user_id
  FROM auth.users
  WHERE email = p_email;
  
  -- Check if there's already an active invitation
  UPDATE public.invitations
  SET status = 'expired',
      updated_at = now()
  WHERE email = p_email AND status = 'pending';
  
  -- Create new invitation
  INSERT INTO public.invitations (
    email,
    user_id,
    waitlist_id,
    status,
    expires_at,
    created_by,
    invitation_type,
    metadata
  ) VALUES (
    p_email,
    v_user_id,
    p_waitlist_id,
    'pending',
    p_expires_at,
    (select auth.uid()),
    p_invitation_type,
    p_metadata
  )
  RETURNING id INTO v_invitation_id;
  
  RETURN v_invitation_id;
END;
$$;

-- Create function to check invitation validity
CREATE OR REPLACE FUNCTION public.get_invitation_info(
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result JSONB;
  v_user_email TEXT;
  v_banned_until TIMESTAMPTZ;
  v_member_id UUID;
  v_is_active BOOLEAN;
  v_invitation_id UUID;
  v_invitation_status public.invitation_status;
  v_invitation_expires_at TIMESTAMPTZ;
  v_first_name TEXT;
  v_last_name TEXT;
  v_phone_number TEXT;
  v_date_of_birth TIMESTAMPTZ;
  v_pronouns TEXT;
  v_gender TEXT;
  v_medical_conditions TEXT;
BEGIN
  -- Get user email and banned status
  SELECT email, banned_until INTO v_user_email, v_banned_until
  FROM auth.users
  WHERE id = p_user_id;
  
  -- Check if user is banned
  IF v_banned_until > now() THEN
    RAISE EXCEPTION USING
      errcode = 'U0003',
      message = 'User is banned.',
      hint = 'Banned until: ' || v_banned_until;
  END IF;
  
  -- Check if user already has a member profile
  SELECT mp.id, up.is_active
  INTO v_member_id, v_is_active
  FROM public.user_profiles up
  LEFT JOIN public.member_profiles mp ON mp.user_profile_id = up.id
  WHERE up.supabase_user_id = p_user_id;
  
  IF v_member_id IS NOT NULL THEN
    RAISE EXCEPTION USING
      errcode = 'U0004',
      message = 'User already has a member profile.',
      hint = 'Member ID: ' || v_member_id;
  END IF;
  
  IF v_is_active THEN
    RAISE EXCEPTION USING
      errcode = 'U0005',
      message = 'User is already active.';
  END IF;
  
  -- Check for valid invitation
  SELECT 
    i.id, i.status, i.expires_at,
    up.first_name, up.last_name, up.phone_number,
    up.date_of_birth, up.pronouns, up.gender,
    up.medical_conditions
  INTO
    v_invitation_id, v_invitation_status, v_invitation_expires_at,
    v_first_name, v_last_name, v_phone_number,
    v_date_of_birth, v_pronouns, v_gender,
    v_medical_conditions
  FROM public.invitations i
  LEFT JOIN public.user_profiles up ON up.supabase_user_id = p_user_id
  WHERE (i.user_id = p_user_id OR i.email = v_user_email)
  AND i.status = 'pending'
  ORDER BY i.created_at DESC
  LIMIT 1;
  
  IF v_invitation_id IS NULL THEN
    -- Check if user has a waitlist entry with completed status
    DECLARE
      v_waitlist_id UUID;
      v_waitlist_status public.waitlist_status;
    BEGIN
      SELECT w.id, w.status
      INTO v_waitlist_id, v_waitlist_status
      FROM public.waitlist w
      JOIN public.user_profiles up ON up.waitlist_id = w.id
      WHERE up.supabase_user_id = p_user_id;
      
      IF v_waitlist_id IS NULL THEN
        RAISE EXCEPTION USING
          errcode = 'U0006',
          message = format('Waitlist entry not found for email: %s', v_user_email),
          hint = 'Email not found in waitlist';
      ELSIF v_waitlist_status NOT IN ('completed', 'invited') THEN
        RAISE EXCEPTION USING
          errcode = 'U0007',
          message = 'This user has not completed the workshop.',
          hint = 'Waitlist status: ' || v_waitlist_status;
      END IF;
      
      -- If we get here, the user has a completed workshop but no invitation
      -- Let's create one automatically
      INSERT INTO public.invitations (
        email,
        user_id,
        waitlist_id,
        status,
        expires_at,
        created_by,
        invitation_type,
        metadata
      ) VALUES (
        v_user_email,
        p_user_id,
        v_waitlist_id,
        'pending',
        now() + interval '30 days',
        p_user_id,
        'workshop',
        jsonb_build_object('auto_created', true, 'waitlist_status', v_waitlist_status)
      )
      RETURNING id INTO v_invitation_id;
    EXCEPTION
      WHEN no_data_found THEN
        RAISE EXCEPTION USING
          errcode = 'U0008',
          message = format('No valid invitation found for email: %s', v_user_email),
          hint = 'Please request an invitation or complete a workshop';
    END;
  END IF;
  
  IF v_invitation_expires_at < now() THEN
    -- Update invitation status to expired
    UPDATE public.invitations
    SET status = 'expired',
        updated_at = now()
    WHERE id = v_invitation_id;
    
    RAISE EXCEPTION USING
      errcode = 'U0009',
      message = 'Invitation has expired.',
      hint = 'Please request a new invitation';
  END IF;
  
  -- Build the result JSONB
  RETURN jsonb_build_object(
    'invitation_id', v_invitation_id,
    'first_name', v_first_name,
    'last_name', v_last_name,
    'phone_number', v_phone_number,
    'date_of_birth', v_date_of_birth,
    'pronouns', v_pronouns,
    'gender', v_gender,
    'medical_conditions', v_medical_conditions
  );
  
EXCEPTION
  WHEN no_data_found THEN
    RAISE EXCEPTION USING
      errcode = 'U0002',
      message = 'User not found.';
  WHEN others THEN
    RAISE;
END;
$$;

-- Create function to update invitation status
CREATE OR REPLACE FUNCTION public.update_invitation_status(
  p_invitation_id UUID,
  p_status public.invitation_status
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Check if caller has admin role or is the user associated with the invitation
  IF NOT (
    public.has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::role_type[]) OR
    EXISTS (
      SELECT 1 FROM public.invitations 
      WHERE id = p_invitation_id AND user_id = (select auth.uid())
    )
  ) THEN
    RAISE EXCEPTION USING
      errcode = 'PERM1',
      message = 'Permission denied: Cannot update invitation status';
  END IF;
  
  UPDATE public.invitations
  SET status = p_status,
      updated_at = now()
  WHERE id = p_invitation_id;
  
  RETURN FOUND;
END;
$$;

-- Create updated_at trigger function if it doesn't exist
CREATE OR REPLACE FUNCTION public.trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add updated_at trigger
CREATE TRIGGER set_updated_at
BEFORE UPDATE ON public.invitations
FOR EACH ROW
EXECUTE FUNCTION public.trigger_set_updated_at();

-- Grant permissions
GRANT SELECT, INSERT, UPDATE ON public.invitations TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_invitation TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_invitation_info TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_invitation_status TO authenticated;
