# Terms of Service & Privacy Policy

Source documents for the two BeatzLock legal pages. These are the master copies
you edit in Word; the copies users read live in the database, pasted in through
the Django admin.

```
terms_of_service_privacy/
├── terms_of_service/
│   └── terms_of_service_v<app-version>.docx
└── privacy_policy/
    └── privacy_policy_v<app-version>.docx
```

## Naming

One pair of documents per app version, named after the version in
`otp_auth_app/pubspec.yaml`. Current: **v1.8.0** (build 45).

Never edit a `.docx` that has already been published. Copy it to the next
version number and edit the copy, so the file on disk still matches what is
live and archived on the site.

## Publishing a new version

Nothing publishes on save any more. The flow is:

1. Write `..._v<next-version>.docx` in this folder.
2. Django admin → **Legal Pages**. To revise a live document, tick the current
   revision in the list and run the **"Duplicate as a new draft"** action — that
   gives you a copy with the same content, unpublished. (Or **Add** a fresh one.)
3. Open the draft. Pick the release from the **App version** dropdown — it is
   populated from **App Releases**, newest first, so there is nothing to type.
   (If the release is not listed, add it under App Releases first.) This is for
   your reference only; users never see it. Then paste the Word content into
   the TinyMCE **Content** box.
4. Save. It stays a **Draft**: invisible to the website and to the app. The
   revision that is already live stays live.
5. Use the **Preview this revision** link in the Publishing section to read the
   draft on the real page. Only staff can open it; visitors still see the live
   document.
6. When it reads right, tick **Published** and save (or use the **"Publish
   selected revisions"** action). The revision it replaces moves to the public
   archive — it is not deleted.

Ticking Published stamps `published_at` once and never rewrites it, so the date
users were shown stays the date users were shown.

## Where these end up

| Surface | URL |
| --- | --- |
| Live Terms | `/legal/terms-of-service/` |
| Terms archive | `/legal/terms-of-service/archive/` |
| One past Terms revision | `/legal/terms-of-service/archive/<id>/` |
| Live Privacy | `/legal/privacy-policy/` |
| Privacy archive | `/legal/privacy-policy/archive/` |
| One past Privacy revision | `/legal/privacy-policy/archive/<id>/` |
| App JSON (live revision only) | `/api/legal/terms/`, `/api/legal/privacy/` |

Drafts never appear on any of these. The JSON endpoint returns the live
revision plus its `published_at` and `archive_url`.

Users identify a revision by its publication timestamp, not by app version —
the archive lists each past revision as "Version of July 19, 2026, 19:45 EAT /
In effect until August 28, 2026, 09:07 EAT". Times render in 24-hour form in
the site timezone (`TIME_ZONE`, currently Africa/Nairobi). `app_version` is admin-side only and is not rendered on
any page or included in the API response.

## Pasting from Word

The documents use Word's built-in styles, which TinyMCE maps cleanly:

| Word style | HTML | Rendered as |
| --- | --- | --- |
| Heading 2 | `<h2>` | Section heading with a rule under it |
| Heading 3 | `<h3>` | Sub-heading |
| List Bullet | `<ul><li>` | Bulleted list |
| Normal | `<p>` | Body text |

Drop the document Title line and the version/date subtitle when you paste — the
page renders its own title from the **Title** field and its own date from
**published_at**, so pasting them in duplicates both.

## Related

An older set of these documents in Markdown lives in `../tos_privacy/`
(dated `02_05_2026`), from before the versioned Word workflow. Kept for
reference; new revisions go here.
