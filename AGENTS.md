# PRHM Git Fast Lane — source-only workflow

این دستورالعمل برای کارهای عادی کدنویسی، UI، رفع باگ و مستندسازی است؛ **مجوز انتشار Production نیست**.

1. مسیر اصلی ثبت تغییر: ابزار متصل GitHub، روی **مخزن درست همین پروژه**. برای ساخت/ویرایش فایل از GitHub Contents API (یا commit اتمیک چندفایلی) استفاده کن؛ برای نوشتن کد در Git، نیاز به SSH Agent، ثبت Host Action، بوت‌استرپ یا مجوز سطح ۴ نیست.
2. قبل از ثبت، فایل و SHA فعلی، شاخه هدف، تغییرات نامرتبط، الزامات امنیتی و انتشار خودکار را بررسی کن. اگر Push به شاخه اصلی ممکن است Production را منتشر کند یا وضعیت نامشخص است، تغییر را فقط در یک شاخه توسعه ثبت کن؛ ادغام/انتشار جداگانه انجام شود.
3. به قوانین اختصاصی مخزن، branch protection، تست و تأییدهای لازم احترام بگذار. بدون ضرورت برای رفع مشکل ابزار، PR یا درخواست تأیید مکرر نساز. هرگز secret، فایل محلی محیط یا کلید را commit نکن.
4. **Git DONE** یعنی مسیر فایل‌ها، repo/branch/SHA و نتیجه واقعی تست/CI گزارش شده باشد. CI اجرا نشده را PASS گزارش نکن.
5. **Production DONE نیست** مگر deploy از SHA مشخص با تأیید متناسب با ریسک، بررسی سلامت، ثبت رویداد و rollback انجام و اثبات شده باشد. ویرایش مستقیم فایل/دیتابیس Production ممنوع است.
6. برای هر درخواست، تمام مراحل کم‌ریسک Git-only را یک‌جا انجام بده و کار را با شواهد واقعی ببند؛ از چرخه تکراری «قدم بعدی» پرهیز کن.

مرجع مشترک: https://github.com/prhmonline/prhm-host-actions/blob/main/docs/fast-git-delivery.md

## PRHM cloud/mobile and low-token policy (2026-11-23)

- **Mobile-first, cloud-first:** accept requests from phone; GitHub is the source of truth. Do not require a powered-on PC, persistent VM, or local checkout for ordinary Git work.
- **Minimum useful tokens:** read the project's required technical map and only task-relevant files; reuse established context; avoid repeated repository scans, unnecessary builds, retries, or long explanations. Never skip essential financial/security/regression checks to save tokens.
- **Output:** report in concise Persian, preferably at most 4 lines: outcome; files + branch/PR/SHA; focused tests and real CI status; blocker/next action. Use short English technical instructions when more efficient.
- **Git safety:** fetch/verify latest default-branch SHA, preserve approved behavior and unrelated work, use a task branch and draft PR. No force-push, hard reset, branch deletion, direct default-branch push, merge, deploy, or Production/data change without separately scoped owner authorization.
- **Environment:** Save/Publish is for cloud-environment settings, not code updates; code uses commit, push and PR. Distinguish successful offline tests from unavailable CI and never claim unseen changes deployed.
- **Precedence:** retain all existing repository-specific instructions, release gates, permissions, recovery safeguards and required approvals; these override efficiency shortcuts.

