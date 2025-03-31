-- Migration to enhance invitation system with better constraint handling and race condition protection
-- Date: 2025-03-26

-- Add a unique constraint on user_id (each user can have only one invitation)
ALTER TABLE public.invitations 
ADD CONSTRAINT user_id_unique UNIQUE (user_id);

-- Modify create_invitation function to handle existing invitations
CREATE OR REPLACE FUNCTION public.create_invitation(
  v_user_id UUID,
  p_email TEXT,
  p_first_name TEXT,
  p_last_name TEXT,
  p_date_of_birth TIMESTAMPTZ,
  p_phone_number TEXT,
  p_invitation_type TEXT,
  p_waitlist_id UUID DEFAULT NULL,
  p_expires_at TIMESTAMPTZ DEFAULT (now() + interval '7 days'),
  p_metadata JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_invitation_id UUID;
  v_existing_invitation UUID;
BEGIN
  -- Check if caller has admin role or is a service role
  IF NOT (
    public.has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::public.role_type[]) OR
    (select current_role) IN ('postgres', 'service_role')
  ) THEN
    RAISE EXCEPTION USING
      errcode = 'PERM1',
      message = 'Permission denied: Admin role required to create invitations';
  END IF;

  -- Check if user already has a pending invitation
  SELECT id INTO v_existing_invitation
  FROM public.invitations
  WHERE user_id = v_user_id AND status = 'pending';
  
  IF v_existing_invitation IS NOT NULL THEN
    -- Update existing invitation instead of creating a new one
    UPDATE public.invitations
    SET status = 'pending',
        expires_at = p_expires_at,
        updated_at = now(),
        metadata = COALESCE(p_metadata, metadata)
    WHERE id = v_existing_invitation
    RETURNING id INTO v_invitation_id;
    
    -- Log the update
    RAISE NOTICE 'Updated existing invitation % for user %', v_invitation_id, v_user_id;
  ELSE
    -- Check if there's already an active invitation with same email
    UPDATE public.invitations
    SET status = 'expired',
        updated_at = now()
    WHERE email = p_email AND status = 'pending';
    
    -- Create user profile if it doesn't exist
    INSERT INTO public.user_profiles (
      supabase_user_id,
      first_name,
      last_name,
      date_of_birth,
      phone_number,
      is_active
    ) VALUES (
      v_user_id,
      p_first_name,
      p_last_name,
      p_date_of_birth,
      p_phone_number,
      false
    )
    ON CONFLICT (supabase_user_id) 
    DO UPDATE SET
      first_name = p_first_name,
      last_name = p_last_name,
      date_of_birth = p_date_of_birth,
      phone_number = p_phone_number;

    INSERT INTO public.user_roles (
      user_id,
      role
    ) values (
      v_user_id,
      'member'
    )
    ON CONFLICT (user_id, role) 
    DO NOTHING;
    
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
  END IF;
  
  RETURN v_invitation_id;
END;
$$;

-- Modify update_invitation_status to use transaction isolation for race condition handling
CREATE OR REPLACE FUNCTION public.update_invitation_status(
  p_invitation_id UUID,
  p_status public.invitation_status
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_status public.invitation_status;
  v_expires_at TIMESTAMPTZ;
BEGIN
  -- Check if caller has admin role, is the user associated with the invitation, or is a service role
  IF NOT (
    public.has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::public.role_type[]) OR
    EXISTS (
      SELECT 1 FROM public.invitations 
      WHERE id = p_invitation_id AND user_id = (select auth.uid())
    ) OR
    (select current_role) IN ('postgres', 'service_role')
  ) THEN
    RAISE EXCEPTION USING
      errcode = 'PERM1',
      message = 'Permission denied: Cannot update invitation status';
  END IF;
  
  -- Get current status with row lock (prevents race conditions)
  SELECT status, expires_at INTO v_status, v_expires_at
  FROM public.invitations
  WHERE id = p_invitation_id
  FOR UPDATE;
  
  -- If no invitation found
  IF v_status IS NULL THEN
    RAISE EXCEPTION USING
      errcode = 'U0011',
      message = 'Invitation not found',
      hint = 'Check invitation ID and try again';
  END IF;
  
  -- Check if invitation has expired
  IF v_expires_at < now() AND v_status = 'pending' THEN
    -- Auto-update to expired
    UPDATE public.invitations
    SET status = 'expired',
        updated_at = now()
    WHERE id = p_invitation_id;
    
    RAISE EXCEPTION USING
      errcode = 'U0009',
      message = 'Invitation has expired',
      hint = 'Please request a new invitation';
  END IF;
  
  -- Ensure valid status transition
  IF (v_status = 'accepted' AND p_status != 'accepted') OR
     (v_status = 'expired' AND p_status != 'expired') OR
     (v_status = 'revoked' AND p_status != 'revoked') THEN
    RAISE EXCEPTION USING
      errcode = 'U0010',
      message = format('Invalid status transition from %s to %s', v_status, p_status),
      hint = 'Cannot change from final status';
  END IF;
  
  -- Update invitation
  UPDATE public.invitations
  SET status = p_status,
      updated_at = now()
  WHERE id = p_invitation_id;
  
  RETURN FOUND;
END;
$$;

-- Modify get_invitation_info to handle race conditions
CREATE OR REPLACE FUNCTION public.get_invitation_info(
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
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
  -- Check if this is a service role or if the user is trying to get their own invitation info
  IF NOT (
    p_user_id = (select auth.uid()) OR
    (select current_role) IN ('postgres', 'service_role') OR
    public.has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::public.role_type[])
  ) THEN
    RAISE EXCEPTION USING
      errcode = 'PERM1',
      message = 'Permission denied: Cannot access invitation info for another user';
  END IF;

  -- Get user email and banned status
  SELECT email, banned_until INTO v_user_email, v_banned_until
  FROM auth.users
  WHERE id = p_user_id
  FOR UPDATE; -- Lock the row to prevent race conditions
  
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
  WHERE up.supabase_user_id = p_user_id
  FOR UPDATE; -- Lock the row to prevent race conditions
  
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
  
  -- Check for valid invitation with FOR UPDATE to lock the row
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
  LIMIT 1
  FOR UPDATE; -- Lock the row to prevent race conditions
  
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
      WHERE up.supabase_user_id = p_user_id
      FOR UPDATE; -- Lock the row to prevent race conditions
      
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
      RETURNING id, status, expires_at INTO v_invitation_id, v_invitation_status, v_invitation_expires_at;
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
    'medical_conditions', v_medical_conditions,
    'status', v_invitation_status
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

-- Create an index to optimize querying pending invitations by email
CREATE INDEX idx_invitations_email_pending
ON public.invitations(email)
WHERE status = 'pending';

-- Add a comment to explain the purpose of this migration
COMMENT ON CONSTRAINT user_id_unique ON public.invitations IS 
'Ensures a user can only have one pending invitation at a time';
