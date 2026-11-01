# Supabase setup

1. Create a Supabase project and open its SQL Editor.
2. Run [`schema.sql`](./schema.sql) once. It creates account profiles, real signup-based referrals, a protected wallet ledger, and payout requests. The auth trigger also checks the submitted birth year and rejects users under 18; the browser check is not the security boundary.
   If you already installed the earlier schema, run [`migrations/20261101_require_adult_birth_year.sql`](./migrations/20261101_require_adult_birth_year.sql) instead. Existing accounts must submit an eligible year before using referrals or payout features.
3. `index.html` is configured with the project URL and publishable key. Publishable/anon keys are intended for browser use; never put a Supabase service-role key in the HTML.
4. In Supabase Dashboard > Authentication > Email Templates, configure the **Confirm signup** template body to include a message such as `Your confirmation code is {{ .Token }}` so Supabase emails a one-time code (not only a confirmation link). Keep email confirmations enabled under Authentication > Sign In / Providers > Email. The page verifies codes using Supabase Auth's `signup` OTP flow and can resend the code.
5. In Authentication > URL Configuration, set the production Site URL and add the exact hosted page URL to Redirect URLs. Add local development URLs while testing.
6. Configure a production SMTP provider under Authentication > SMTP Settings. Supabase's built-in email service is intended for testing and currently allows only 2 emails per hour across the project; signup confirmations and resend requests share that quota. Custom SMTP is needed for normal production signup volume. The app also enforces a 60-second cooldown between confirmation-code resend attempts.
7. Serve the page over HTTP/HTTPS and test registration, code confirmation, direct email-and-password sign-in, referral links, and payout requests. Password recovery is not available in the app.

The existing quiz is practice content, not paid research. It does not create wallet credits. Referral signups are recorded only when a real Supabase account is created; signing up or paying a fee does not generate a bonus. Wallet credits can only be written by a trusted server using a verified, funded reward policy. Build that server-side verification before offering cash rewards.

Age is checked using the submitted birth year. Since the form collects only a year and not a full birth date, the cutoff is intentionally conservative (current year minus 19) so a person who has not yet turned 18 cannot pass based on an upcoming birthday.

Payout requests reserve the requested amount in the database, and a rejected request is automatically returned to the wallet. This page does not send money or integrate M-Pesa/bank payouts; an authorized backend/operator must review and fulfill requests. Users must not be charged a fee to unlock or release a payout.

The former `jazapesa_data_v2` local browser data is not used as account, password, referral, or balance storage. Only quiz question content may be retained locally.
