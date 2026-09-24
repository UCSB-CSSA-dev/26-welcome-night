import { createClient } from "@supabase/supabase-js";

const url =
  (import.meta.env.VITE_SUPABASE_URL as string | undefined) ||
  (import.meta.env.NEXT_PUBLIC_SUPABASE_URL as string | undefined);

const anonKey =
  (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) ||
  (import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined) ||
  (import.meta.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY as string | undefined);

if (!url || !anonKey) {
  console.warn(
    "缺少 Supabase 环境变量。请在 .env.local 中设置 NEXT_PUBLIC_SUPABASE_URL 与 NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
  );
}

export const supabase = createClient(
  url ?? "https://placeholder.supabase.co",
  anonKey ?? "placeholder-key",
);

export function publicImageUrl(path: string | null | undefined): string | null {
  if (!path) return null;
  if (path.startsWith("http") || path.startsWith("data:")) return path;
  const { data } = supabase.storage.from("prize-images").getPublicUrl(path);
  return data.publicUrl;
}

export function rpcErrorMessage(err: unknown): string {
  if (!err) return "未知错误";
  if (typeof err === "object" && err !== null && "message" in err) {
    const msg = String((err as { message: string }).message);
    const match = msg.match(/ERROR:\s*(.+?)(?:\s+CONTEXT:|$)/i);
    if (match?.[1]) return match[1].trim();
    return msg.replace(/^.*error:\s*/i, "").trim() || msg;
  }
  return String(err);
}

export function isSupabaseConfigured(): boolean {
  return Boolean(url && anonKey);
}
