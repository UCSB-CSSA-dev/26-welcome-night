-- Delete device session (user must re-apply for a new code)
CREATE OR REPLACE FUNCTION admin_delete_session(p_token UUID, p_session_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_admin(p_token);

  IF NOT EXISTS (SELECT 1 FROM sessions WHERE id = p_session_id) THEN
    RAISE EXCEPTION '设备会话不存在';
  END IF;

  -- draw_history.session_id is ON DELETE SET NULL
  DELETE FROM sessions WHERE id = p_session_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_delete_session(UUID, UUID) TO anon, authenticated;
