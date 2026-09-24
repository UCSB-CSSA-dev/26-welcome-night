-- Fix: Supabase rejects DELETE without WHERE (pg_safeupdate)
CREATE OR REPLACE FUNCTION generate_lottery(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_units BIGINT[];
  v_nums INT[];
  v_i INT;
BEGIN
  PERFORM assert_admin(p_token);

  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  IF v_cfg.status <> 'setup' AND v_cfg.current_cursor > 0 THEN
    RAISE EXCEPTION '抽奖进行中，请先「重新开始」或使用「调整总数」';
  END IF;

  SELECT coalesce(array_agg(prize_id), ARRAY[]::BIGINT[])
  INTO v_units FROM expand_prize_units();

  IF coalesce(array_length(v_units, 1), 0) > v_cfg.total_number THEN
    RAISE EXCEPTION '奖品总数（%）不能超过总人数（%）',
      array_length(v_units, 1), v_cfg.total_number;
  END IF;

  DELETE FROM draw_history WHERE id IS NOT NULL;
  DELETE FROM prize_assignments WHERE id IS NOT NULL;

  IF coalesce(array_length(v_units, 1), 0) > 0 THEN
    v_nums := pick_unique_numbers(array_length(v_units, 1), 1, v_cfg.total_number);
    FOR v_i IN 1..array_length(v_units, 1) LOOP
      INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
      VALUES (v_units[v_i], v_nums[v_i], FALSE);
    END LOOP;
  END IF;

  UPDATE lottery_config
  SET current_cursor = 0, status = 'running', updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION restart_lottery(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg lottery_config%ROWTYPE;
  v_units BIGINT[];
  v_nums INT[];
  v_i INT;
BEGIN
  PERFORM assert_admin(p_token);
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  SELECT coalesce(array_agg(prize_id), ARRAY[]::BIGINT[])
  INTO v_units FROM expand_prize_units();

  IF coalesce(array_length(v_units, 1), 0) > v_cfg.total_number THEN
    RAISE EXCEPTION '奖品总数（%）不能超过总人数（%）',
      array_length(v_units, 1), v_cfg.total_number;
  END IF;

  DELETE FROM draw_history WHERE id IS NOT NULL;
  DELETE FROM prize_assignments WHERE id IS NOT NULL;

  IF coalesce(array_length(v_units, 1), 0) > 0 THEN
    v_nums := pick_unique_numbers(array_length(v_units, 1), 1, v_cfg.total_number);
    FOR v_i IN 1..array_length(v_units, 1) LOOP
      INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
      VALUES (v_units[v_i], v_nums[v_i], FALSE);
    END LOOP;
  END IF;

  UPDATE lottery_config
  SET current_cursor = 0, status = 'running', updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at
  );
END;
$$;
