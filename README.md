# UCSB CSSA Welcome Night 抽奖

多设备同步转盘抽奖：前端 React（Render 静态站），后端 **Supabase**（Postgres RPC + Storage）。

## 功能

- 管理员设置总人数与奖品（名称、描述、数量、图片），生成随机号码映射
- 设备申请 6 位码，管理员审批后方可抽奖
- `FOR UPDATE` 行锁保证多端并发按序取号
- 未映射号码为「谢谢参与」；已抽奖品不可再中
- 中途可「重新开始」或「调整总数」（重映射剩余奖品）

## 1. 配置 Supabase

1. 打开 [Supabase Dashboard](https://supabase.com/dashboard) → 你的项目 → **SQL Editor**
2. 粘贴并执行 [`supabase/all.sql`](supabase/all.sql)（或按 `migrations/` 顺序执行三个文件）
3. 再执行一次（换成你的密码）：

```sql
SELECT set_admin_password('你的管理员密码');
```

4. Project Settings → API，确认 `.env.local` 中有：

```bash
NEXT_PUBLIC_SUPABASE_URL=https://xxxx.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...   # 或 legacy anon JWT
```

也支持 Vite 变量名：`VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY`。

## 2. 本地运行

```bash
npm install
npm run dev
```

打开 http://localhost:5173 — 抽奖页；`/admin` — 管理后台。

## 3. 部署前端到 Render（免费静态站）

1. 将仓库推到 GitHub
2. Render → **Static Site** → 连接仓库
3. 设置：
   - **Root Directory:** `client`（或留空并用下方 build）
   - **Build Command:** `npm install && npm run build`（若 root 为仓库根目录：`npm install && npm run build -w client`）
   - **Publish Directory:** `client/dist`（root=仓库时）或 `dist`（root=`client` 时）
4. Environment：

| Key | Value |
|-----|--------|
| `VITE_SUPABASE_URL` | 同 Supabase URL |
| `VITE_SUPABASE_ANON_KEY` | 同 publishable / anon key |

> 不要把 service_role key 放进前端。

## 活动当晚流程

1. `/admin` 登录 → 添加奖品 → 设总人数 → **生成奖池并开始**
2. 各设备打开首页 → **申请抽奖设备** → 管理员点 **通过**
3. 设备点 **开始抽奖**，转盘停止显示结果
4. 如需改总人数：点 **保存 / 调整总数**（已抽不变，剩余奖品重映射）

## 项目结构

```
client/                 React + Tailwind + shadcn 风格组件
supabase/migrations/    表结构 + RPC（抽奖锁、管理、设备）
supabase/all.sql        一键粘贴版本
```
