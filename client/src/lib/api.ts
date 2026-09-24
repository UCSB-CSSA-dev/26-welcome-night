import { supabase, rpcErrorMessage, publicImageUrl } from "./supabase";
import type {
  DeviceSession,
  DrawResult,
  LotteryConfig,
  LotteryState,
  Prize,
} from "./types";

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(rpcErrorMessage(error));
  return data as T;
}

export async function fetchLotteryState(): Promise<LotteryState> {
  return rpc<LotteryState>("get_lottery_state");
}

export async function createSession(label = ""): Promise<DeviceSession> {
  return rpc<DeviceSession>("create_device_session", { p_label: label });
}

export async function countApprovedSessions(): Promise<number> {
  const { count, error } = await supabase
    .from("sessions")
    .select("id", { count: "exact", head: true })
    .eq("approved", true);
  if (error) throw new Error(rpcErrorMessage(error));
  return count ?? 0;
}

export async function getSession(id: string): Promise<DeviceSession | null> {
  const { data, error } = await supabase
    .from("sessions")
    .select("id, code, approved, label, created_at")
    .eq("id", id)
    .maybeSingle();
  if (error) throw new Error(rpcErrorMessage(error));
  if (!data) return null;
  return {
    id: data.id,
    code: data.code,
    approved: data.approved,
    label: data.label,
    createdAt: data.created_at,
  };
}

export async function drawNext(sessionId: string): Promise<DrawResult> {
  return rpc<DrawResult>("draw_next", { p_session_id: sessionId });
}

export async function adminLogin(password: string): Promise<{ token: string }> {
  const data = await rpc<{ token: string; expiresAt: string }>("admin_login", {
    p_password: password,
  });
  return { token: data.token };
}

export async function adminLogout(token: string): Promise<void> {
  await rpc("admin_logout", { p_token: token });
}

export async function adminMe(token: string): Promise<boolean> {
  try {
    await rpc("admin_me", { p_token: token });
    return true;
  } catch {
    return false;
  }
}

export async function generateLottery(token: string): Promise<LotteryConfig> {
  return rpc<LotteryConfig>("generate_lottery", { p_token: token });
}

export async function restartLottery(token: string): Promise<LotteryConfig> {
  return rpc<LotteryConfig>("restart_lottery", { p_token: token });
}

export async function setTotalNumber(
  token: string,
  totalNumber: number,
): Promise<LotteryConfig> {
  return rpc<LotteryConfig>("set_total_number", {
    p_token: token,
    p_total: totalNumber,
  });
}

export async function getLotterySequence(token: string): Promise<unknown> {
  return rpc("get_lottery_sequence", { p_token: token });
}

export async function lockLotterySequence(
  token: string,
  hash: string,
): Promise<{
  ok: boolean;
  sequenceLocked: boolean;
  sequenceHash: string;
  sequenceLockedAt: string;
}> {
  return rpc("lock_lottery_sequence", {
    p_token: token,
    p_hash: hash,
  });
}

export async function unlockLotterySequence(token: string): Promise<void> {
  await rpc("unlock_lottery_sequence", { p_token: token });
}

export async function importLotterySequence(
  token: string,
  document: unknown,
): Promise<LotteryConfig> {
  return rpc<LotteryConfig>("import_lottery_sequence", {
    p_token: token,
    p_document: document,
  });
}

export async function createPrize(
  token: string,
  input: {
    name: string;
    description: string;
    quantity: number;
    imagePath?: string | null;
    sortOrder?: number;
  },
): Promise<Prize> {
  return rpc<Prize>("admin_create_prize", {
    p_token: token,
    p_name: input.name,
    p_description: input.description,
    p_quantity: input.quantity,
    p_image_path: input.imagePath ?? null,
    p_sort_order: input.sortOrder ?? 0,
  });
}

export async function updatePrize(
  token: string,
  id: number,
  input: {
    name?: string;
    description?: string;
    quantity?: number;
    imagePath?: string | null;
    sortOrder?: number;
    clearImage?: boolean;
  },
): Promise<Prize> {
  return rpc<Prize>("admin_update_prize", {
    p_token: token,
    p_id: id,
    p_name: input.name ?? null,
    p_description: input.description ?? null,
    p_quantity: input.quantity ?? null,
    p_image_path: input.imagePath ?? null,
    p_sort_order: input.sortOrder ?? null,
    p_clear_image: input.clearImage ?? false,
  });
}

export async function deletePrize(token: string, id: number): Promise<void> {
  await rpc("admin_delete_prize", { p_token: token, p_id: id });
}

export async function listSessions(): Promise<DeviceSession[]> {
  const { data, error } = await supabase
    .from("sessions")
    .select("id, code, approved, label, created_at")
    .order("created_at", { ascending: false });
  if (error) throw new Error(rpcErrorMessage(error));
  return (data ?? []).map((d) => ({
    id: d.id,
    code: d.code,
    approved: d.approved,
    label: d.label,
    createdAt: d.created_at,
  }));
}

export async function setSessionApproved(
  token: string,
  sessionId: string,
  approved: boolean,
): Promise<DeviceSession> {
  return rpc<DeviceSession>("set_session_approved", {
    p_token: token,
    p_session_id: sessionId,
    p_approved: approved,
  });
}

export async function deleteSession(
  token: string,
  sessionId: string,
): Promise<void> {
  await rpc("admin_delete_session", {
    p_token: token,
    p_session_id: sessionId,
  });
}

export async function uploadPrizeImage(file: File): Promise<string> {
  const ext = file.name.split(".").pop()?.toLowerCase() || "jpg";
  const path = `${crypto.randomUUID()}.${ext}`;
  const { error } = await supabase.storage
    .from("prize-images")
    .upload(path, file, { contentType: file.type, upsert: false });
  if (error) throw new Error(error.message);
  return path;
}

export { publicImageUrl };
