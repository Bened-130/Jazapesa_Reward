# Publish JazaPesa on Vercel

This project is a static HTML app. It has no build step or npm dependencies.

## Deploy

1. Put the project files in a GitHub repository. The repository root should contain `index.html` and `vercel.json`.
2. In Vercel, choose **Add New → Project**, import that repository, and deploy.
3. Use the project root as the Root Directory, **Other** as the Framework Preset, and leave the Build Command and Install Command empty. `vercel.json` serves the project root and sets basic response security headers.
4. Open the production deployment URL and check registration, email-code confirmation, login, referral links, and logged-in account pages.

The Supabase URL and publishable key in `index.html` are browser-facing credentials. Do not replace the publishable key with a Supabase `service_role` or secret key. The `supabase` folder contains database SQL, not secret credentials.

## Supabase production settings

Before sharing the site with users:

1. Run `supabase/schema.sql` in the Supabase SQL Editor for a fresh database. If the earlier schema is already installed, use the migration instructions in [`supabase/README.md`](./supabase/README.md) instead.
2. In Supabase Authentication URL Configuration, set the Site URL to the Vercel production URL and add that exact URL to Redirect URLs. Add the final custom domain too if you connect one.
3. Enable email confirmations, configure the Confirm signup email template to include `{{ .Token }}`, and set up production SMTP. Verify code delivery using a real test account.
4. Keep database Row Level Security enabled and never put secret keys in browser code.

## Before advertising cash rewards

This deployment only publishes the current app; it does not add a paid-research service or payment processor. Quizzes are practice-only, referral signups do not create cash bonuses, and payout requests are not sent to M-Pesa or a bank. Do not advertise guaranteed earnings or accept fees for surveys or withdrawals. A verified, funded rewards backend and a real payout process are needed before offering cash rewards.
