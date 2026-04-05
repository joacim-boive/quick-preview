const { Readable } = require("node:stream");

const {
  bridgePublicBaseURL,
  parseCookieHeader,
  signPayload,
  siteBaseURL,
  verifySignedPayload,
} = require("./_shared");

const COOKIE_NAME = "QuickPreviewProDl";
const COOKIE_MAX_AGE_SEC = 600;
const DOWNLOAD_FILENAME = "QuickPreviewPro.zip";

function cookieAttributes(selfPath, maxAgeSec) {
  const secure =
    process.env.VERCEL || process.env.NODE_ENV === "production" ? "; Secure" : "";
  return `Path=${selfPath}; HttpOnly; SameSite=Lax; Max-Age=${maxAgeSec}${secure}`;
}

function downloadSourceURL() {
  return new URL(`/downloads/${DOWNLOAD_FILENAME}`, `${siteBaseURL()}/`).toString();
}

async function proxyDownload(res, selfPath) {
  const upstream = await fetch(downloadSourceURL(), { redirect: "follow" });
  if (!upstream.ok || !upstream.body) {
    throw new Error(
      `Could not fetch ${DOWNLOAD_FILENAME} from the static site (HTTP ${upstream.status}).`
    );
  }

  res.statusCode = 200;
  res.setHeader(
    "Content-Type",
    upstream.headers.get("content-type") || "application/zip"
  );
  res.setHeader(
    "Content-Disposition",
    `attachment; filename="${DOWNLOAD_FILENAME}"`
  );
  res.setHeader("Cache-Control", "no-store, private");
  res.setHeader("Set-Cookie", `${COOKIE_NAME}=; ${cookieAttributes(selfPath, 0)}`);

  const contentLength = upstream.headers.get("content-length");
  if (contentLength) {
    res.setHeader("Content-Length", contentLength);
  }

  Readable.fromWeb(upstream.body).pipe(res);
}

module.exports = async function handler(req, res) {
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
      const setCookie = `${COOKIE_NAME}=${cookieVal}; ${cookieAttributes(
        selfPath,
        COOKIE_MAX_AGE_SEC
      )}`;

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

    await proxyDownload(res, selfPath);
  } catch (error) {
    res.status(500).send(error instanceof Error ? error.message : "Download page error.");
  }
};
