# WalkWorthy public hosting

Static pages served from Firebase Hosting: the marketing/landing page, Privacy
Policy, Consumer Health Data Policy, AI Safety Information, and Terms of Use. These are the URLs referenced from the iOS app
(Settings → About and the create-account consent line) and from App Store
Connect metadata.

## Files

- `index.html` — landing page linking to the policies, AI safety, and support.
- `privacy.html` — Privacy Policy (required by Apple for submission).
- `health-data.html` — Consumer Health Data Privacy Policy.
- `ai-safety.html` — generated-content limits, safety handling, support, and reporting.
- `terms.html` — Terms of Use (not Apple-required, but linked from the app).
- `style.css` — shared styling, dark-mode-aware.

## Deploy

```
firebase deploy --only hosting
```

Requires the Firebase CLI (`npm install -g firebase-tools`) and being logged in
(`firebase login`) with access to the `walkworthy-app` project.

After a deploy, URLs resolve at:

- `https://walkworthy-app.web.app/` (landing)
- `https://walkworthy-app.web.app/privacy`
- `https://walkworthy-app.web.app/health-data`
- `https://walkworthy-app.web.app/ai-safety`
- `https://walkworthy-app.web.app/terms`

The iOS app links directly to these URLs. If you move hosting to a custom
domain later, also update:

- `WalkWorthy/WalkWorthy/UI/Settings/SettingsView.swift` (policy and Terms link URLs)
- `WalkWorthy/WalkWorthy/UI/Auth/SignInFormView.swift` (`legalConsentText` URLs)
- App Store Connect → App Information → Privacy Policy URL

## Content updates

Edit the HTML directly, bump the `<time datetime="...">` value at the top, and
redeploy. If the change is material, notify users in-app or by email per the
Privacy Policy's "Changes to this policy" section.
