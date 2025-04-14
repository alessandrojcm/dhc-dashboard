
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
