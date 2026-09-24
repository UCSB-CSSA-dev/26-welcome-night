import { publicImageUrl } from "@/lib/api";
import type { DrawResult } from "@/lib/types";
import { Button } from "@/components/ui/button";

interface ResultModalProps {
  result: DrawResult;
  onClose: () => void;
}

export function ResultModal({ result, onClose }: ResultModalProps) {
  const won = !result.thankYou && result.prize;
  const image = won ? publicImageUrl(result.prize!.imagePath) : null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="result-title"
    >
      <button
        type="button"
        className="absolute inset-0 bg-navy-deep/65 backdrop-blur-[2px]"
        aria-label="关闭"
        onClick={onClose}
      />
      <div className="animate-result-pop relative z-10 w-full max-w-sm overflow-hidden rounded-2xl border border-gold/50 bg-gradient-to-b from-[#fffdf8] to-[#f3ebe0] shadow-[0_25px_80px_rgba(0,26,51,0.45)]">
        <div className="h-1.5 w-full bg-gradient-to-r from-navy via-gold to-navy" />
        <div className="px-6 pb-6 pt-7 text-center">
          <p className="text-xs font-medium tracking-[0.2em] text-navy/50">
            第 {result.orderNumber} 号
          </p>
          <h2
            id="result-title"
            className="font-display mt-2 text-3xl font-bold text-navy"
          >
            {won ? "恭喜中奖！" : "谢谢参与"}
          </h2>

          {won ? (
            <>
              {image ? (
                <img
                  src={image}
                  alt=""
                  className="mx-auto mt-5 h-28 w-28 rounded-xl object-cover shadow-md ring-2 ring-gold/40"
                />
              ) : (
                <div className="mx-auto mt-5 flex h-28 w-28 items-center justify-center rounded-xl bg-navy/5 text-4xl text-gold">
                  🎁
                </div>
              )}
              <p className="mt-4 text-xl font-semibold text-navy">
                {result.prize!.name}
              </p>
              {result.prize!.description ? (
                <p className="mt-1 text-sm text-ink/60">
                  {result.prize!.description}
                </p>
              ) : null}
            </>
          ) : (
            <p className="mt-5 text-sm leading-relaxed text-ink/65">
              好运留给下一位，感谢参与 UCSB CSSA Welcome Night！
            </p>
          )}

          <Button
            variant="gold"
            size="lg"
            className="mt-7 w-full"
            onClick={onClose}
          >
            好的
          </Button>
        </div>
      </div>
    </div>
  );
}
