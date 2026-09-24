import { useEffect, useState } from "react";
import type { Prize } from "@/lib/types";
import { publicImageUrl } from "@/lib/api";
import { Button } from "@/components/ui/button";
import { Input, Label, Textarea } from "@/components/ui/input";

export type PrizeFormValues = {
  name: string;
  description: string;
  quantity: number;
};

interface PrizeFormModalProps {
  mode: "create" | "edit";
  prize?: Prize | null;
  busy?: boolean;
  onClose: () => void;
  onSave: (values: PrizeFormValues) => void | Promise<void>;
  onUploadImage?: (file: File) => void | Promise<void>;
}

export function PrizeFormModal({
  mode,
  prize,
  busy,
  onClose,
  onSave,
  onUploadImage,
}: PrizeFormModalProps) {
  const [name, setName] = useState(prize?.name ?? "");
  const [description, setDescription] = useState(prize?.description ?? "");
  const [quantity, setQuantity] = useState(String(prize?.quantity ?? 1));

  // Only seed fields when opening / switching prize — not on every parent re-render
  const prizeId = prize?.id ?? null;
  useEffect(() => {
    setName(prize?.name ?? "");
    setDescription(prize?.description ?? "");
    setQuantity(String(prize?.quantity ?? 1));
    // intentionally not depending on full prize object
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, prizeId]);

  const image = publicImageUrl(prize?.imagePath ?? null);
  const title = mode === "create" ? "添加奖品" : "编辑奖品";

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="prize-form-title"
    >
      <button
        type="button"
        className="absolute inset-0 bg-navy-deep/55 backdrop-blur-[2px]"
        aria-label="关闭"
        onClick={onClose}
      />
      <div className="animate-result-pop relative z-10 w-full max-w-md overflow-hidden rounded-2xl border border-navy/10 bg-white shadow-xl">
        <div className="border-b border-navy/10 px-5 py-4">
          <h2 id="prize-form-title" className="text-lg font-semibold text-navy">
            {title}
          </h2>
        </div>
        <div className="space-y-3 px-5 py-4">
          {mode === "edit" ? (
            <div className="flex items-center gap-3">
              {image ? (
                <img
                  src={image}
                  alt=""
                  className="h-16 w-16 rounded-md object-cover"
                />
              ) : (
                <div className="flex h-16 w-16 items-center justify-center rounded-md bg-navy/5 text-xs text-navy/40">
                  无图
                </div>
              )}
              {onUploadImage ? (
                <label className="cursor-pointer text-sm text-navy underline">
                  更换图片
                  <input
                    type="file"
                    accept="image/*"
                    className="hidden"
                    disabled={busy}
                    onChange={(e) => {
                      const file = e.target.files?.[0];
                      if (file) void onUploadImage(file);
                    }}
                  />
                </label>
              ) : null}
            </div>
          ) : null}
          <div>
            <Label>名称</Label>
            <Input
              value={name}
              onChange={(e) => setName(e.target.value)}
              disabled={busy}
              placeholder="例如：一等奖"
              autoFocus
            />
          </div>
          <div>
            <Label>描述</Label>
            <Textarea
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              disabled={busy}
              placeholder="可选"
            />
          </div>
          <div>
            <Label>数量</Label>
            <Input
              type="number"
              min={1}
              value={quantity}
              onChange={(e) => setQuantity(e.target.value)}
              disabled={busy}
            />
          </div>
        </div>
        <div className="flex justify-end gap-2 border-t border-navy/10 px-5 py-3">
          <Button variant="ghost" onClick={onClose} disabled={busy}>
            取消
          </Button>
          <Button
            variant="gold"
            disabled={busy || !name.trim()}
            onClick={() =>
              void onSave({
                name: name.trim(),
                description,
                quantity: Math.max(1, Number(quantity) || 1),
              })
            }
          >
            {mode === "create" ? "添加" : "保存"}
          </Button>
        </div>
      </div>
    </div>
  );
}

/** @deprecated use PrizeFormModal */
export const PrizeEditModal = PrizeFormModal;
