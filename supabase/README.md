# Supabase SQL

## Fresh project
Run [`all.sql`](./all.sql) once, then:

```sql
SELECT set_admin_password('SBCSSA2026');
```

## Existing project (updates)
If the app already works but new buttons fail (序列锁定 / 删除设备 / etc.), run **only**:

[`patch_latest.sql`](./patch_latest.sql)

in **SQL Editor → New query → Run**.

This patch includes:
- pgcrypto password helpers
- generate/restart DELETE … WHERE fixes
- delete prize (mid-lottery)
- sequence lock / export RPCs
- delete device session
