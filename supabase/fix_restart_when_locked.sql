-- Allow restart while sequence is locked: clear progress, replay same numbers.
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
  v_text TEXT;
  v_prize RECORD;
  v_qty INT;
  v_idx INT := 1;
  v_total INT;
BEGIN
  PERFORM assert_admin(p_token);
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1 FOR UPDATE;

  DELETE FROM draw_history WHERE id IS NOT NULL;
  DELETE FROM prize_assignments WHERE id IS NOT NULL;

  IF v_cfg.sequence_locked THEN
    IF coalesce(v_cfg.sequence_numbers, '') = '' THEN
      RAISE EXCEPTION '已锁定但缺少号码序列，请先解锁后重新生成';
    END IF;

    v_text := v_cfg.sequence_numbers;
    SELECT coalesce(array_agg(trim(x)::INT ORDER BY ord), ARRAY[]::INT[])
    INTO v_nums
    FROM unnest(string_to_array(v_text, ',')) WITH ORDINALITY AS t(x, ord)
    WHERE trim(x) <> '';

    v_total := v_cfg.total_number;
    IF coalesce(array_length(v_nums, 1), 0) <> v_total THEN
      RAISE EXCEPTION '锁定序列长度与总人数不一致';
    END IF;

    FOR v_prize IN
      SELECT p.id, p.quantity, p.name
      FROM prizes p
      ORDER BY p.sort_order ASC, p.id ASC
    LOOP
      v_qty := v_prize.quantity;
      IF v_idx + v_qty - 1 > v_total THEN
        RAISE EXCEPTION '奖品数量超过总人数（奖品「%」）', v_prize.name;
      END IF;
      FOR v_i IN 1..v_qty LOOP
        INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
        VALUES (v_prize.id, v_nums[v_idx], FALSE);
        v_idx := v_idx + 1;
      END LOOP;
    END LOOP;

    UPDATE lottery_config
    SET current_cursor = 0,
        status = 'running',
        updated_at = NOW()
    WHERE id = 1
    RETURNING * INTO v_cfg;

    RETURN jsonb_build_object(
      'totalNumber', v_cfg.total_number,
      'currentCursor', v_cfg.current_cursor,
      'status', v_cfg.status,
      'updatedAt', v_cfg.updated_at,
      'sequenceLocked', true,
      'sequenceHash', v_cfg.sequence_hash,
      'sequenceNumbers', v_cfg.sequence_numbers
    );
  END IF;

  SELECT coalesce(array_agg(prize_id), ARRAY[]::BIGINT[])
  INTO v_units FROM expand_prize_units();

  IF coalesce(array_length(v_units, 1), 0) > v_cfg.total_number THEN
    RAISE EXCEPTION '奖品总数（%）不能超过总人数（%）',
      array_length(v_units, 1), v_cfg.total_number;
  END IF;

  IF coalesce(array_length(v_units, 1), 0) > 0 THEN
    v_nums := pick_unique_numbers(array_length(v_units, 1), 1, v_cfg.total_number);
    FOR v_i IN 1..array_length(v_units, 1) LOOP
      INSERT INTO prize_assignments (prize_id, assigned_number, drawn)
      VALUES (v_units[v_i], v_nums[v_i], FALSE);
    END LOOP;
  END IF;

  UPDATE lottery_config
  SET current_cursor = 0,
      status = 'running',
      sequence_numbers = NULL,
      sequence_hash = NULL,
      sequence_locked = FALSE,
      sequence_locked_at = NULL,
      updated_at = NOW()
  WHERE id = 1
  RETURNING * INTO v_cfg;

  PERFORM ensure_sequence_numbers();
  SELECT * INTO v_cfg FROM lottery_config WHERE id = 1;

  RETURN jsonb_build_object(
    'totalNumber', v_cfg.total_number,
    'currentCursor', v_cfg.current_cursor,
    'status', v_cfg.status,
    'updatedAt', v_cfg.updated_at,
    'sequenceLocked', false,
    'sequenceNumbers', v_cfg.sequence_numbers
  );
END;
$$;

GRANT EXECUTE ON FUNCTION restart_lottery(UUID) TO anon, authenticated;
