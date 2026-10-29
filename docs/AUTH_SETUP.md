# Bibbles account setup

Bibbles uses the Supabase project configured in `Resources/Info.plist`. The URL and publishable key are public client settings. Never put a service-role key, Google client secret, or Apple signing key in the app or repository.

## Supabase

1. In Authentication → URL Configuration, add `bibbles-auth://callback` to **Additional Redirect URLs**. Keep your normal website as Site URL.
2. In Authentication → Providers, leave Email enabled if you want email/password sign-in. Enable email confirmation for public signup and configure an SMTP sender before launch.
3. In Authentication → Providers → Google, enable Google after completing the Google Cloud steps below. In Providers → Apple, enable Apple after completing the Apple Developer steps below.
4. Keep Row Level Security enabled on any account-owned data you add later. The current Mac app does not upload chat history, screenshots, or provider API keys when someone signs in.

## Google

1. In Google Cloud, configure the OAuth consent screen and publish it for your intended audience.
2. Create an OAuth client of type **Web application**. Set its Authorized redirect URI to `https://eoaybgiwtjshmfdoqxqx.supabase.co/auth/v1/callback`.
3. Put that client's ID and secret in **Supabase Authentication → Providers → Google**, then enable the provider. The secret stays in Supabase, never in Bibbles.
4. Test with an allowed Google account. If the consent screen remains in Testing, add each tester in Google Cloud.

## Apple

The default development build uses Apple's web OAuth flow, which needs a configured Services ID. A release build can use the native Apple account sheet when the app's App ID and signing profile have the Sign in with Apple capability.

1. In Apple Developer, enable **Sign in with Apple** for Bibbles' App ID. For the web flow, create a Services ID associated with that App ID.
2. Configure the Services ID domain as `eoaybgiwtjshmfdoqxqx.supabase.co` and return URL as `https://eoaybgiwtjshmfdoqxqx.supabase.co/auth/v1/callback`.
3. Create the Apple sign-in key. Enter the Services ID, Team ID, Key ID, and generated client secret in **Supabase Authentication → Providers → Apple**. Store the `.p8` signing key privately. Put the Services ID before the native App ID in Supabase's Client IDs list when using both flows.
4. For a signed native build whose App ID has the capability, set `BIBBLES_APPLE_SIGN_IN=1` when running `scripts/build-dev-app.sh`. The build signs with `Resources/AppleSignIn.entitlements`; the Account page then uses the native Apple button.

## Verify

Open Bibbles → Settings → Account. The Account page checks the project's public provider settings. A social button is available only when that provider is enabled. Sign up with email, follow the confirmation link back to Bibbles, sign out, and sign in again. Repeat with Google and Apple accounts. Quit and reopen Bibbles to check that the Keychain-backed session is restored. Test a password reset link as well.

Signing in also authorizes Bibbles' Worker requests. Account → Monthly usage reads the plan and limits from `/v1/me`; chat history and screenshots remain local unless a future feature explicitly sends them for a task.
