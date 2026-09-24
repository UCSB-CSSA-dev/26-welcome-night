import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { toast } from "sonner";
import {
  adminLogin,
  adminLogout,
  adminMe,
  createPrize,
  deletePrize,
  deleteSession,
  fetchLotteryState,
  generateLottery,
  getLotterySequence,
  importLotterySequence,
  listSessions,
  lockLotterySequence,
  publicImageUrl,
  reorderPrizes,
  restartLottery,
  setSessionApproved,
  setTotalNumber,
  unlockLotterySequence,
  updatePrize,
  uploadPrizeImage,
} from "@/lib/api";
import {
  clearAdminToken,
  loadAdminToken,
  saveAdminToken,
  type DeviceSession,
  type LotteryState,
  type Prize,
} from "@/lib/types";
import { Button } from "@/components/ui/button";
import { Input, Label } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { PrizeFormModal } from "@/components/PrizeFormModal";
import {
  downloadTextFile,
  hashSequencePayload,
  parseImportDocument,
} from "@/lib/sequence";

export function AdminPage() {
  const [token, setToken] = useState<string | null>(null);
  const [password, setPassword] = useState("");
  const [state, setState] = useState<LotteryState | null>(null);
  const [sessions, setSessions] = useState<DeviceSession[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [totalInput, setTotalInput] = useState("100");
  const [totalDirty, setTotalDirty] = useState(false);
  const [editing, setEditing] = useState<Prize | null>(null);
  const [adding, setAdding] = useState(false);
  const [lastExportHash, setLastExportHash] = useState<string | null>(null);
  const importFileRef = useRef<HTMLInputElement>(null);

  const refresh = useCallback(async () => {
    const [s, sess] = await Promise.all([
      fetchLotteryState(),
      listSessions(),
    ]);
    setState(s);
    setSessions(sess);
    setTotalInput((prev) => {
      // Don't clobber in-progress typing
      if (totalDirty) return prev;
      return String(s.config.totalNumber);
    });
    setEditing((prev) => {
      if (!prev) return null;
      const latest = s.prizes.find((p) => p.id === prev.id);
      if (!latest) return null;
      if (latest.imagePath === prev.imagePath) return prev;
      return { ...prev, imagePath: latest.imagePath };
    });
  }, [totalDirty]);

  useEffect(() => {
    const t = loadAdminToken();
    if (!t) return;
    void (async () => {
      const ok = await adminMe(t);
      if (ok) {
        setToken(t);
        try {
          await refresh();
        } catch (e) {
          setError(e instanceof Error ? e.message : "加载失败");
        }
      } else {
        clearAdminToken();
      }
    })();
  }, [refresh]);

  useEffect(() => {
    if (!token) return;
    const id = window.setInterval(() => {
      void refresh().catch(() => undefined);
    }, 2500);
    return () => window.clearInterval(id);
  }, [token, refresh]);

  async function handleLogin(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      const { token: t } = await adminLogin(password);
      saveAdminToken(t);
      setToken(t);
      setPassword("");
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "登录失败");
    } finally {
      setBusy(false);
    }
  }

  async function handleLogout() {
    if (token) {
      try {
        await adminLogout(token);
      } catch {
        /* ignore */
      }
    }
    clearAdminToken();
    setToken(null);
  }

  async function run(action: () => Promise<void>, okMsg: string) {
    if (!token) return;
    setError(null);
    setBusy(true);
    try {
      await action();
      await refresh();
      toast.success(okMsg);
    } catch (err) {
      const msg = err instanceof Error ? err.message : "操作失败";
      setError(msg);
      toast.error(msg);
    } finally {
      setBusy(false);
    }
  }

  if (!token) {
    return (
      <div className="mx-auto flex min-h-dvh max-w-md flex-col justify-center px-4">
        <Card className="bg-white text-ink">
          <h1 className="mb-1 text-2xl font-bold text-navy">管理员登录</h1>
          <p className="mb-4 text-sm text-ink/60">UCSB CSSA Welcome Night 抽奖</p>
          <form onSubmit={(e) => void handleLogin(e)}>
            <Label htmlFor="pw">密码</Label>
            <Input
              id="pw"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="mb-4"
              autoFocus
            />
            {error ? <p className="mb-3 text-sm text-red-700">{error}</p> : null}
            <Button type="submit" variant="gold" className="w-full" disabled={busy}>
              登录
            </Button>
          </form>
          <Link
            to="/"
            className="mt-4 block text-center text-xs text-navy/50 hover:underline"
          >
            返回抽奖页
          </Link>
        </Card>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-3xl space-y-6 px-4 py-8 text-ink">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-white sm:text-3xl">抽奖管理</h1>
          <p className="text-sm text-white/55">Welcome Night · 后台</p>
        </div>
        <div className="flex gap-2">
          <Link
            to="/"
            className="inline-flex h-8 items-center rounded-md border border-white/20 bg-white/10 px-3 text-xs text-white hover:bg-white/20"
          >
            抽奖页
          </Link>
          <Button
            variant="ghost"
            size="sm"
            className="text-white/70 hover:bg-white/10 hover:text-white"
            onClick={() => void handleLogout()}
          >
            退出
          </Button>
        </div>
      </div>

      {error ? (
        <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-800">{error}</p>
      ) : null}

      <Card>
        <h2 className="mb-3 text-lg font-semibold text-navy">抽奖设置</h2>
        <div className="mb-4 flex flex-wrap gap-4 text-sm text-ink/70">
          <span>
            状态：
            <strong className="text-navy">
              {state?.config.status === "setup"
                ? "准备中"
                : state?.config.status === "running"
                  ? "进行中"
                  : "已结束"}
            </strong>
          </span>
          <span>
            进度：
            <strong className="text-navy">
              {state?.config.currentCursor}/{state?.config.totalNumber}
            </strong>
          </span>
          <span>
            剩余奖品：
            <strong className="text-navy">{state?.remainingPrizes ?? 0}</strong>
          </span>
          <span>
            序列：
            <strong className="text-navy">
              {state?.config.sequenceLocked ? "已锁定" : "未锁定"}
            </strong>
          </span>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <div>
            <Label htmlFor="total">总人数 / 总号码</Label>
            <Input
              id="total"
              type="number"
              min={1}
              value={totalInput}
              disabled={!!state?.config.sequenceLocked}
              onChange={(e) => {
                setTotalDirty(true);
                setTotalInput(e.target.value);
              }}
              className="w-36"
            />
          </div>
          <Button
            disabled={busy || !!state?.config.sequenceLocked}
            title={
              state?.config.sequenceLocked ? "序列已锁定，请先解锁" : undefined
            }
            onClick={() =>
              void run(async () => {
                const n = Number(totalInput);
                if (!Number.isInteger(n) || n < 1) {
                  throw new Error("总人数必须是正整数");
                }
                await setTotalNumber(token, n);
                setTotalDirty(false);
              }, "总人数已更新")
            }
          >
            保存 / 调整总数
          </Button>
          <Button
            variant="gold"
            disabled={busy || !!state?.config.sequenceLocked}
            title={
              state?.config.sequenceLocked ? "序列已锁定，请先解锁" : undefined
            }
            onClick={() =>
              void run(async () => {
                await generateLottery(token);
              }, "奖池已生成，抽奖开始")
            }
          >
            生成奖池并开始
          </Button>
          <Button
            variant="danger"
            disabled={busy || !!state?.config.sequenceLocked}
            title={
              state?.config.sequenceLocked ? "序列已锁定，请先解锁" : undefined
            }
            onClick={() => {
              if (!window.confirm("确定重新开始？已抽记录将清空。")) return;
              void run(async () => {
                await restartLottery(token);
              }, "已重新开始");
            }}
          >
            重新开始
          </Button>
        </div>
      </Card>

      <Card>
        <h2 className="mb-2 text-lg font-semibold text-navy">号码序列锁定 / 导出</h2>
        <p className="mb-3 text-sm text-ink/60">
          导出格式为一串号码（按奖品排序：一等奖号码 → 二等奖号码 → …
          → 其余谢谢参与号码），例如{" "}
          <code className="rounded bg-navy/5 px-1 font-mono text-xs">
            12, 13, 42, 45, 18, …
          </code>
          。锁定后该列表写入数据库并固定；之后调整奖品顺序或新增奖品都不会改动已锁定列表。哈希即对该字符串求
          SHA-256。
        </p>
        {state?.config.sequenceNumbers ? (
          <p className="mb-3 max-h-24 overflow-y-auto break-all rounded-md bg-navy/5 px-3 py-2 font-mono text-xs text-navy">
            已存序列：{state.config.sequenceNumbers}
          </p>
        ) : null}
        {state?.config.sequenceHash ? (
          <p className="mb-3 break-all rounded-md bg-navy/5 px-3 py-2 font-mono text-xs text-navy">
            已存哈希：{state.config.sequenceHash}
          </p>
        ) : null}
        {lastExportHash ? (
          <p className="mb-3 break-all rounded-md bg-emerald-50 px-3 py-2 font-mono text-xs text-emerald-900">
            本次哈希：{lastExportHash}
          </p>
        ) : null}
        <input
          ref={importFileRef}
          type="file"
          accept="application/json,.json,.txt,text/plain"
          className="hidden"
          onChange={(e) => {
            const file = e.target.files?.[0];
            e.target.value = "";
            if (!file || !token) return;
            if (
              !window.confirm(
                "导入将按当前奖品顺序覆盖号码映射、清空已抽记录并重置进度。确定继续？",
              )
            ) {
              return;
            }
            void run(async () => {
              const text = await file.text();
              let parsed: unknown = text.trim();
              if (text.trim().startsWith("{") || text.trim().startsWith("[")) {
                try {
                  parsed = JSON.parse(text) as unknown;
                } catch {
                  parsed = text.trim();
                }
              }
              const document = parseImportDocument(parsed);
              const { hash } = await hashSequencePayload(document);
              await importLotterySequence(token, document);
              setLastExportHash(hash);
              setTotalDirty(false);
            }, "号码序列已导入（进度已重置）");
          }}
        />
        <div className="flex flex-wrap gap-2">
          <Button
            variant="outline"
            disabled={busy || state?.config.status === "setup"}
            onClick={() =>
              void run(async () => {
                const payload = await getLotterySequence(token);
                const { numbersText, hash } =
                  await hashSequencePayload(payload);
                setLastExportHash(hash);
                downloadTextFile(
                  `welcome-night-numbers.txt`,
                  numbersText,
                  "text/plain;charset=utf-8",
                );
              }, "号码列表已下载（请对此文件内容求 SHA-256）")
            }
          >
            导出号码列表
          </Button>
          <Button
            variant="outline"
            disabled={busy || !!state?.config.sequenceLocked}
            title={
              state?.config.sequenceLocked ? "序列已锁定，请先解锁" : undefined
            }
            onClick={() => importFileRef.current?.click()}
          >
            导入号码列表
          </Button>
          <Button
            variant="outline"
            disabled={busy || state?.config.status === "setup"}
            onClick={() =>
              void run(async () => {
                const payload = await getLotterySequence(token);
                const { hash } = await hashSequencePayload(payload);
                setLastExportHash(hash);
                downloadTextFile(
                  `welcome-night-numbers.sha256.txt`,
                  `${hash}\n`,
                  "text/plain;charset=utf-8",
                );
                try {
                  await navigator.clipboard.writeText(hash);
                } catch {
                  /* ignore */
                }
              }, "哈希已生成（已尝试复制）")
            }
          >
            生成 / 导出哈希
          </Button>
          <Button
            variant="gold"
            disabled={
              busy ||
              state?.config.status === "setup" ||
              !!state?.config.sequenceLocked
            }
            onClick={() =>
              void run(async () => {
                const payload = await getLotterySequence(token);
                const { hash } = await hashSequencePayload(payload);
                await lockLotterySequence(token, hash);
                setLastExportHash(hash);
              }, "号码序列已锁定")
            }
          >
            锁定序列
          </Button>
          <Button
            variant="ghost"
            disabled={busy || !state?.config.sequenceLocked}
            onClick={() => {
              if (!window.confirm("确定解锁序列？之后可再次调整/生成。")) return;
              void run(async () => {
                await unlockLotterySequence(token);
                setLastExportHash(null);
              }, "序列已解锁");
            }}
          >
            解锁序列
          </Button>
        </div>
        <p className="mt-3 text-xs text-ink/45">
          验证步骤：下载「号码列表」→ 打开{" "}
          <a
            href="https://emn178.github.io/online-tools/sha256.html"
            target="_blank"
            rel="noopener noreferrer"
            className="font-medium text-navy underline underline-offset-2 hover:text-navy/70"
          >
            在线 SHA-256 工具 ↗
          </a>
          → 粘贴文件全部内容（含逗号与空格，勿改格式）→ 结果应与页面哈希一致。
        </p>
      </Card>

      <Card>
        <div className="mb-3 flex items-center justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold text-navy">奖品管理</h2>
            <p className="text-xs text-ink/50">
              列表顺序 = 奖等顺序（最上为一等奖）。可用上/下调整。
            </p>
          </div>
          <Button
            variant="gold"
            size="sm"
            disabled={busy}
            onClick={() => setAdding(true)}
          >
            添加奖品
          </Button>
        </div>

        {(state?.prizes ?? []).length === 0 ? (
          <p className="text-sm text-ink/50">暂无奖品，点击右上角添加</p>
        ) : (
          <ul className="space-y-3">
            {(state?.prizes ?? []).map((p, index) => (
              <li
                key={p.id}
                className="flex flex-wrap items-center gap-3 border-t border-navy/10 pt-3 first:border-t-0 first:pt-0"
              >
                <div className="flex flex-col gap-1">
                  <Button
                    size="sm"
                    variant="outline"
                    className="h-7 px-2"
                    disabled={busy || index === 0}
                    title="上移"
                    onClick={() => {
                      const prizes = state?.prizes ?? [];
                      if (index <= 0) return;
                      const ids = prizes.map((x) => x.id);
                      const tmp = ids[index - 1]!;
                      ids[index - 1] = ids[index]!;
                      ids[index] = tmp;
                      void run(async () => {
                        await reorderPrizes(token, ids);
                      }, "奖品顺序已更新");
                    }}
                  >
                    ↑
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    className="h-7 px-2"
                    disabled={busy || index >= (state?.prizes.length ?? 0) - 1}
                    title="下移"
                    onClick={() => {
                      const prizes = state?.prizes ?? [];
                      if (index >= prizes.length - 1) return;
                      const ids = prizes.map((x) => x.id);
                      const tmp = ids[index + 1]!;
                      ids[index + 1] = ids[index]!;
                      ids[index] = tmp;
                      void run(async () => {
                        await reorderPrizes(token, ids);
                      }, "奖品顺序已更新");
                    }}
                  >
                    ↓
                  </Button>
                </div>
                {publicImageUrl(p.imagePath) ? (
                  <img
                    src={publicImageUrl(p.imagePath)!}
                    alt=""
                    className="h-14 w-14 rounded-md object-cover"
                  />
                ) : (
                  <div className="flex h-14 w-14 items-center justify-center rounded-md bg-navy/5 text-xs text-navy/40">
                    无图
                  </div>
                )}
                <div className="min-w-0 flex-1">
                  <div className="font-semibold text-navy">
                    <span className="mr-1.5 text-xs font-medium text-ink/40">
                      #{index + 1}
                    </span>
                    {p.name}{" "}
                    <span className="text-sm font-normal text-ink/50">
                      ×{p.quantity}
                    </span>
                  </div>
                  <div className="truncate text-xs text-ink/55">
                    {p.description}
                  </div>
                </div>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => setEditing(p)}
                >
                  编辑
                </Button>
                <Button
                  size="sm"
                  variant="danger"
                  disabled={busy}
                  onClick={() => {
                    if (!window.confirm(`确定删除「${p.name}」？`)) return;
                    void run(async () => {
                      await deletePrize(token, p.id);
                    }, "已删除");
                  }}
                >
                  删除
                </Button>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card>
        <h2 className="mb-3 text-lg font-semibold text-navy">设备审批</h2>
        {sessions.length === 0 ? (
          <p className="text-sm text-ink/50">暂无设备申请</p>
        ) : (
          <ul className="space-y-2">
            {sessions.map((s) => (
              <li
                key={s.id}
                className="flex flex-wrap items-center justify-between gap-2 rounded-md bg-navy/[0.03] px-3 py-2"
              >
                <div>
                  <span className="font-mono text-lg font-bold tracking-widest text-navy">
                    {s.code}
                  </span>
                  {s.label ? (
                    <span className="ml-2 text-sm text-ink/55">{s.label}</span>
                  ) : null}
                  <span
                    className={`ml-2 text-xs ${s.approved ? "text-emerald-700" : "text-amber-700"}`}
                  >
                    {s.approved ? "已通过" : "待审批"}
                  </span>
                </div>
                <div className="flex flex-wrap gap-2">
                  <Button
                    size="sm"
                    variant={s.approved ? "outline" : "gold"}
                    disabled={busy}
                    onClick={() =>
                      void run(async () => {
                        await setSessionApproved(token, s.id, !s.approved);
                      }, s.approved ? "已撤销" : "已通过")
                    }
                  >
                    {s.approved ? "撤销" : "通过"}
                  </Button>
                  <Button
                    size="sm"
                    variant="danger"
                    disabled={busy}
                    onClick={() => {
                      if (
                        !window.confirm(
                          `删除设备「${s.code}」？该设备需重新申请新号码。`,
                        )
                      ) {
                        return;
                      }
                      void run(async () => {
                        await deleteSession(token, s.id);
                      }, "设备已删除");
                    }}
                  >
                    删除
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card>
        <h2 className="mb-3 text-lg font-semibold text-navy">已抽记录</h2>
        <ul className="max-h-64 space-y-1 overflow-y-auto text-sm">
          {(state?.history ?? []).map((h) => (
            <li
              key={h.orderNumber}
              className="flex justify-between border-b border-navy/5 py-1"
            >
              <span className="text-ink/45">#{h.orderNumber}</span>
              <span className="font-medium text-navy">
                {h.prizeName ?? "谢谢参与"}
              </span>
            </li>
          ))}
          {(state?.history.length ?? 0) === 0 ? (
            <li className="text-ink/45">暂无记录</li>
          ) : null}
        </ul>
      </Card>

      {adding ? (
        <PrizeFormModal
          mode="create"
          busy={busy}
          onClose={() => setAdding(false)}
          onSave={(values) =>
            void run(async () => {
              await createPrize(token, values);
              setAdding(false);
            }, "奖品已添加")
          }
        />
      ) : null}

      {editing ? (
        <PrizeFormModal
          mode="edit"
          prize={editing}
          busy={busy}
          onClose={() => setEditing(null)}
          onSave={(patch) =>
            void run(async () => {
              await updatePrize(token, editing.id, patch);
              setEditing(null);
            }, "奖品已更新")
          }
          onUploadImage={(file) =>
            void run(async () => {
              const path = await uploadPrizeImage(file);
              await updatePrize(token, editing.id, { imagePath: path });
            }, "图片已上传")
          }
        />
      ) : null}
    </div>
  );
}
