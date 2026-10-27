# Deploy station claims for testing

1. Create an Edge Function named `stamp-claim` using `index.js` in this directory. It has no dependencies.
2. Turn off Verify JWT with legacy secret and save. The function verifies the LINE access token's channel and identity, then checks friendship with the official account linked to LINE Login channel 2012241831.
3. In SQL Editor run:

```sql
update public.stamp_stations set active = true where id between 1 and 6;
```

Keep LINE Login in Developing while testing. Confirm the linked official account is 雙創營銷顧問有限公司 (add-friend URL https://lin.ee/O6l2xhh). Profile scope and Scan QR must be enabled on LIFF.

Each existing QR URL contains `station=1` through `station=6`. It works from LINE's scanner or the web page's Scan QR button. After adding a friend, return to the web page and press the continue button if automatic recheck does not run. The station is retained on that browser for up to one hour. Browsers that isolate storage may require scanning again.

Acceptance checks: new friend flow; existing friend; blocked account; one stamp per station; repeat same QR; close and reopen; different account cannot see another account's stamps. Function and UI mocks pass, but these device/database checks still require the deployed function.

This is a test implementation: station URLs are public and shareable and do not establish physical presence. It has no event-time enforcement yet. Redemption is disabled and requires its own staff authorization and atomic database rules. Do not treat this as a complete production event system.
