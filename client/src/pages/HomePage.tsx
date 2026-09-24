import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import {
  countApprovedSessions,
  createSession,
  drawNext,
  fetchLotteryState,
  getSession,
} from "@/lib/api";
import {
  clearSessionId,
  loadSessionId,
  saveSessionId,
  type DeviceSession,
  type DrawResult,
  type LotteryState,
} from "@/lib/types";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import {
  LotteryWheel,
  resultToSegmentIndex,
} from "@/components/LotteryWheel";
import { ResultModal } from "@/components/ResultModal";
import { cn } from "@/lib/utils";

type SyncStatus = "online" | "multi" | "offline";

export function HomePage() {
  const [state, setState] = useState<LotteryState | null>(null);
  const [session, setSession] = useState<DeviceSession | null>(null);
  const [label, setLabel] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [spinning, setSpinning] = useState(false);
  const [targetIndex, setTargetIndex] = useState<number | null>(null);
  const [resultModal, setResultModal] = useState<DrawResult | null>(null);
  const [pendingResult, setPendingResult] = useState<DrawResult | null>(null);
  const [syncStatus, setSyncStatus] = useState<SyncStatus>("offline");
  const [approvedDevices, setApprovedDevices] = useState(0);

  const refresh = useCallback(async () => {
    try {
      const [s, deviceCount] = await Promise.all([
        fetchLotteryState(),
        countApprovedSessions().catch(() => 0),
      ]);
      setState(s);
      setApprovedDevices(deviceCount);
      setError(null);
      if (!navigator.onLine) {
        setSyncStatus("offline");
      } else if (deviceCount > 1) {
        setSyncStatus("multi");
      } else {
        setSyncStatus("online");
      }
    } catch (e) {
      setSyncStatus("offline");
      setError(e instanceof Error ? e.message : "加载失败");
    }
  }, []);

  useEffect(() => {
    void refresh();
    const id = window.setInterval(() => void refresh(), 2000);
    const onOffline = () => setSyncStatus("offline");
    const onOnline = () => void refresh();
    window.addEventListener("offline", onOffline);
    window.addEventListener("online", onOnline);
    return () => {
      window.clearInterval(id);
      window.removeEventListener("offline", onOffline);
      window.removeEventListener("online", onOnline);
    };
  }, [refresh]);

  const prizeHistory = useMemo(
    () =>
      (state?.history ?? []).filter((h) => h.prizeId != null && h.prizeName),
    [state?.history],
  );

  const syncLabel =
    syncStatus === "offline"
      ? "离线 / 同步异常"
      : syncStatus === "multi"
        ? `多设备在线（${approvedDevices}）`
        : "已连接";

  useEffect(() => {
    const sid = loadSessionId();
    if (!sid) return;
    void (async () => {
      try {
        const s = await getSession(sid);
        if (s) setSession(s);
        else clearSessionId();
      } catch {
        clearSessionId();
      }
    })();
  }, []);

  useEffect(() => {
    if (!session || session.approved) return;
    const id = window.setInterval(async () => {
      try {
        const s = await getSession(session.id);
        if (s) setSession(s);
      } catch {
        /* ignore */
      }
    }, 1500);
    return () => window.clearInterval(id);
  }, [session]);

  async function handleRegister() {
    setError(null);
    setBusy(true);
    try {
      const s = await createSession(label);
      saveSessionId(s.id);
      setSession(s);
    } catch (e) {
      setError(e instanceof Error ? e.message : "注册失败");
    } finally {
      setBusy(false);
    }
  }

  async function handleDraw() {
    if (!session?.approved || spinning || busy) return;
    setError(null);
    setBusy(true);
    setResultModal(null);
    try {
      const result = await drawNext(session.id);
      const idx = resultToSegmentIndex(
        state?.prizes ?? [],
        result.prize,
        result.thankYou,
      );
      setPendingResult(result);
      setTargetIndex(idx);
      setSpinning(true);
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : "抽奖失败");
      setBusy(false);
    }
  }

  function handleSpinEnd() {
    setSpinning(false);
    setBusy(false);
    if (pendingResult) {
      setResultModal(pendingResult);
      setPendingResult(null);
    }
    void refresh();
  }

  const canDraw =
    !!session?.approved &&
    state?.config.status === "running" &&
    !spinning &&
    !busy;

  const statusText =
    state?.config.status === "setup"
      ? "准备中"
      : state?.config.status === "running"
        ? "进行中"
        : "已结束";

  return (
    <div className="relative mx-auto flex min-h-dvh max-w-5xl flex-col px-4 py-4 lg:py-5">
      <div
        aria-hidden
        className="pointer-events-none absolute left-[28%] top-1/2 h-64 w-64 -translate-x-1/2 -translate-y-1/2 rounded-full bg-gold/10 blur-3xl lg:left-[32%]"
      />

      {/* Top bar: brand + sync */}
      <header className="animate-fade-up relative z-10 mb-3 flex items-center justify-between gap-3">
        <div className="min-w-0">
          <p className="text-[10px] font-medium tracking-[0.22em] text-gold-soft/80">
            UCSB CSSA
          </p>
          <h1 className="font-sans truncate text-xl font-bold text-white sm:text-2xl">
            Welcome Night{" "}
            <span className="text-gold-soft">抽奖</span>
          </h1>
        </div>
        <div className="flex shrink-0 items-center gap-2 rounded-full border border-white/10 bg-white/5 px-3 py-1.5">
          <div
            className={cn(
              "h-2.5 w-2.5 rounded-full",
              syncStatus === "offline" && "sync-dot-offline",
              syncStatus === "online" && "sync-dot-online",
              syncStatus === "multi" && "sync-dot-multi",
            )}
            title={syncLabel}
            aria-label={syncLabel}
          />
          <span className="text-[11px] text-white/55">{syncLabel}</span>
        </div>
      </header>

      {/* Main: wheel | side panel */}
      <div className="animate-fade-up relative z-10 grid flex-1 grid-cols-1 items-center gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(260px,320px)] lg:gap-8">
        <div className="flex justify-center lg:justify-end">
          <LotteryWheel
            prizes={state?.prizes ?? []}
            spinning={spinning}
            targetIndex={targetIndex}
            onSpinEnd={handleSpinEnd}
            className={cn(
              "max-w-[min(90vw,520px)] lg:max-w-[min(58vh,560px)]",
              spinning && "animate-pulse-ring rounded-full",
            )}
          />
        </div>

        <aside className="mx-auto w-full max-w-md space-y-3 lg:mx-0 lg:max-w-none">
          {!session ? (
            <Card className="border-white/10 bg-white/95 p-4 text-ink">
              <p className="mb-2 text-sm text-ink/70">
                申请设备码，管理员通过后即可抽奖。
              </p>
              <Input
                placeholder="设备备注（可选）"
                value={label}
                onChange={(e) => setLabel(e.target.value)}
                className="mb-2"
              />
              <Button
                variant="gold"
                className="w-full"
                disabled={busy}
                onClick={() => void handleRegister()}
              >
                申请抽奖设备
              </Button>
            </Card>
          ) : !session.approved ? (
            <Card className="border-gold/30 bg-white/95 p-4 text-center text-ink">
              <p className="text-xs text-ink/70">请告知管理员此设备码</p>
              <p className="my-2 font-sans text-4xl font-bold tracking-[0.25em] text-navy">
                {session.code}
              </p>
              <p className="text-xs text-ink/45">等待审批中…</p>
            </Card>
          ) : (
            <Button
              variant="gold"
              size="lg"
              className="w-full text-base shadow-[0_8px_30px_rgba(212,160,23,0.35)]"
              disabled={!canDraw}
              onClick={() => void handleDraw()}
            >
              {spinning
                ? "抽奖中…"
                : state?.config.status === "finished"
                  ? "抽奖已结束"
                  : state?.config.status === "setup"
                    ? "等待管理员开启"
                    : "开始抽奖"}
            </Button>
          )}

          {error ? (
            <p className="rounded-md bg-red-950/50 px-3 py-2 text-center text-sm text-red-200">
              {error}
            </p>
          ) : null}

          {state ? (
            <div className="grid grid-cols-3 gap-2 rounded-xl border border-white/10 bg-white/5 px-3 py-2.5 text-center text-[11px] text-white/45">
              <div>
                <div className="text-sm font-semibold text-gold-soft">
                  {state.config.currentCursor}/{state.config.totalNumber}
                </div>
                <div>已抽/总数</div>
              </div>
              <div>
                <div className="text-sm font-semibold text-gold-soft">
                  {state.remainingPrizes}
                </div>
                <div>剩余奖品</div>
              </div>
              <div>
                <div className="text-sm font-semibold text-gold-soft">
                  {statusText}
                </div>
                <div>状态</div>
              </div>
            </div>
          ) : null}

          {prizeHistory.length > 0 ? (
            <Card className="border-white/10 bg-white/10 p-3 text-white backdrop-blur-md">
              <h2 className="mb-1.5 text-xs font-semibold text-gold-soft">
                最近中奖
              </h2>
              <ul className="max-h-28 space-y-0.5 overflow-y-auto text-sm lg:max-h-[min(28vh,180px)]">
                {prizeHistory.slice(0, 12).map((h) => (
                  <li
                    key={h.orderNumber}
                    className="flex justify-between gap-2 border-b border-white/10 py-1 last:border-0"
                  >
                    <span className="text-white/40">#{h.orderNumber}</span>
                    <span className="font-medium text-white/90">
                      {h.prizeName}
                    </span>
                  </li>
                ))}
              </ul>
            </Card>
          ) : null}

          <div className="pt-1 text-center lg:text-left">
            <Link
              to="/admin"
              className="text-[11px] text-white/30 underline-offset-2 hover:text-white/60 hover:underline"
            >
              管理员入口
            </Link>
          </div>
        </aside>
      </div>

      {resultModal ? (
        <ResultModal
          result={resultModal}
          onClose={() => setResultModal(null)}
        />
      ) : null}
    </div>
  );
}
