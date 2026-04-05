const {
  bridgePublicBaseURL,
  parseCookieHeader,
  signPayload,
  siteBaseURL,
  verifySignedPayload,
} = require("./_shared");

const COOKIE_NAME = "QuickPreviewProDl";
const COOKIE_MAX_AGE_SEC = 600;

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderPage(email, proAccessToken) {
  const site = siteBaseURL();
  const emailEsc = escapeHtml(email);
  const deepLink = new URL("quickpreview-pro://pro-session");
  deepLink.searchParams.set("token", proAccessToken);
  deepLink.searchParams.set("email", email);
  const deepLinkHref = escapeHtml(deepLink.toString());

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Download QuickPreview PRO</title>
  <meta name="robots" content="noindex, nofollow" />
  <meta name="referrer" content="no-referrer" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Manrope:wght@400;500;700;800&family=Teko:wght@500;600;700&display=swap" rel="stylesheet" />
  <link rel="stylesheet" href="${site}/assets/styles.css" />
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <div class="site-shell">
    <header class="site-header">
      <div class="container header-inner">
        <a class="brand" href="${site}/" aria-label="QuickPreview home">
          <img class="brand-mark" src="${site}/assets/brand-icon.png" alt="" width="48" height="48" />
          <span class="brand-text">
            <strong>QuickPreview</strong>
            <span>Fast video review for macOS</span>
          </span>
        </a>
      </div>
    </header>
    <main id="main">
      <section class="page-hero">
        <div class="container">
          <div class="section-heading">
            <p class="eyebrow">Download</p>
            <h1 class="display">Finish QuickPreview PRO on this Mac.</h1>
            <p class="section-copy">
              This page was opened from your linked subscription. The sign-in link below is shown only on this secure session — do not share your browser session with others.
            </p>
          </div>
        </div>
      </section>
      <section class="section">
        <div class="container card-grid card-grid-3">
          <article class="feature-card">
            <h3>Download the app</h3>
            <p class="card-copy">Install the signed direct edition on the Mac where you want Finder-follow.</p>
            <p><a class="button button-primary" href="${site}/downloads/QuickPreviewPro.zip">Download QuickPreview PRO</a></p>
          </article>
          <article class="feature-card">
            <h3>Apply the token</h3>
            <p class="card-copy">Open QuickPreview PRO with your mirrored access token.</p>
            <p><a class="button button-secondary" href="${deepLinkHref}">Open QuickPreview PRO</a></p>
          </article>
          <article class="feature-card">
            <h3>Need a fresh link?</h3>
            <p class="card-copy">Relink from the Mac App Store edition via Account &amp; QuickPreview PRO, then the subscriber portal.</p>
            <p><a class="button button-secondary" href="${site}/pro/">Back to subscriber portal</a></p>
          </article>
        </div>
      </section>
      <section class="section">
        <div class="container">
          <div class="cta-band">
            <h2 class="display">Token status</h2>
            <p>Ready for <strong>${emailEsc}</strong>. Use the button above after QuickPreview PRO is installed.</p>
            <p class="caption">Session expires in about ${Math.floor(COOKIE_MAX_AGE_SEC / 60)} minutes. Token value is not stored in the page URL after the first redirect.</p>
          </div>
        </div>
      </section>
    </main>
    <footer class="site-footer">
      <div class="container footer-inner">
        <p class="footer-copy">QuickPreview PRO download &amp; sign-in (bridge session).</p>
      </div>
    </footer>
  </div>
</body>
</html>`;
}

module.exports = function handler(req, res) {
  if (req.method !== "GET") {
    res.status(405).setHeader("Allow", "GET").send("Method not allowed.");
    return;
  }

  try {
    const ticket = req.query?.t || req.query?.ticket;
    const base = bridgePublicBaseURL();
    const selfPath = "/api/bridge/pro-download";

    if (ticket && typeof ticket === "string") {
      const payload = verifySignedPayload(ticket);
      if (payload.type !== "proDownloadTicket" || !payload.proAccessToken || !payload.email) {
        res.status(400).send("Invalid download link.");
        return;
      }
      const exp = new Date(payload.exp);
      if (Number.isNaN(exp.getTime()) || exp.getTime() < Date.now()) {
        res.status(400).send("This download link has expired. Start again from the Mac App Store linking flow.");
        return;
      }

      const session = signPayload({
        type: "proDownloadSession",
        proAccessToken: payload.proAccessToken,
        email: payload.email,
        exp: payload.exp,
      });

      const cookieVal = encodeURIComponent(session);
      const secure = process.env.VERCEL || process.env.NODE_ENV === "production" ? "; Secure" : "";
      const setCookie = `${COOKIE_NAME}=${cookieVal}; Path=${selfPath}; HttpOnly; SameSite=Lax; Max-Age=${COOKIE_MAX_AGE_SEC}${secure}`;

      const dest = new URL(selfPath, `${base}/`).toString();
      res.writeHead(302, {
        Location: dest,
        "Set-Cookie": setCookie,
        "Cache-Control": "no-store",
      });
      res.end();
      return;
    }

    const cookies = parseCookieHeader(req.headers.cookie);
    const rawSession = cookies[COOKIE_NAME];
    if (!rawSession) {
      res
        .status(403)
        .setHeader("Content-Type", "text/html; charset=utf-8")
        .send(
          `<!doctype html><meta charset="utf-8"><title>Sign-in required</title><p>Open the download link from QuickPreview after linking your subscription (Mac App Store → account flow). Or <a href="${siteBaseURL()}/pro/">return to the subscriber portal</a>.</p>`
        );
      return;
    }

    let sessionPayload;
    try {
      sessionPayload = verifySignedPayload(rawSession);
    } catch {
      res.status(403).send("Session invalid. Open a fresh link from the Mac App Store edition.");
      return;
    }

    if (sessionPayload.type !== "proDownloadSession") {
      res.status(403).send("Session invalid.");
      return;
    }

    const exp = new Date(sessionPayload.exp);
    if (Number.isNaN(exp.getTime()) || exp.getTime() < Date.now()) {
      res.status(403).send("Session expired. Link again from the Mac App Store edition.");
      return;
    }

    const html = renderPage(sessionPayload.email, sessionPayload.proAccessToken);
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.setHeader("Cache-Control", "no-store, private");
    res.status(200).send(html);
  } catch (error) {
    res.status(500).send(error instanceof Error ? error.message : "Download page error.");
  }
};
