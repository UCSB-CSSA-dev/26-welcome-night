-- Allow deleting prizes even mid-lottery
CREATE OR REPLACE FUNCTION admin_delete_prize(p_token UUID, p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM assert_admin(p_token);

  IF NOT EXISTS (SELECT 1 FROM prizes WHERE id = p_id) THEN
    RAISE EXCEPTION '奖品不存在';
  END IF;

  -- Cascades undrawn/drawn assignments; draw_history.prize_id becomes NULL
  DELETE FROM prizes WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;
