const path = require("node:path");
const { Readable } = require("node:stream");
const { get } = require("@vercel/blob");

const {
  bridgePublicBaseURL,
  parseCookieHeader,
  signPayload,
  siteBaseURL,
  verifySignedPayload,
} = require("./_shared");

const COOKIE_NAME = "QuickPreviewProDl";
const COOKIE_MAX_AGE_SEC = 600;
const DOWNLOAD_FILENAME = "QuickPreviewPro.dmg";

function cookieAttributes(selfPath, maxAgeSec) {
  const secure =
    process.env.VERCEL || process.env.NODE_ENV === "production" ? "; Secure" : "";
  return `Path=${selfPath}; HttpOnly; SameSite=Lax; Max-Age=${maxAgeSec}${secure}`;
}

function blobPathname() {
  const value = process.env.QUICKPREVIEW_PRO_BLOB_PATHNAME;
  if (!value || !String(value).trim()) {
    throw new Error(
      "Set QUICKPREVIEW_PRO_BLOB_PATHNAME to the private Vercel Blob pathname for QuickPreview PRO."
    );
  }
  return String(value).trim().replace(/^\/+/, "");
}

function downloadFilename() {
  const pathname = blobPathname();
  return path.posix.basename(pathname) || DOWNLOAD_FILENAME;
}

async function proxyDownload(res, selfPath) {
  let upstream;
  try {
    upstream = await get(blobPathname(), { access: "private" });
  } catch (error) {
    throw new Error(
      error instanceof Error
        ? `Could not fetch ${downloadFilename()} from private Vercel Blob: ${error.message}`
        : `Could not fetch ${downloadFilename()} from private Vercel Blob.`
    );
  }

  if (!upstream?.stream) {
    throw new Error(`Private Vercel Blob did not return a readable stream for ${downloadFilename()}.`);
  }

  res.statusCode = 200;
  res.setHeader(
    "Content-Type",
    upstream.contentType || "application/zip"
  );
  res.setHeader(
    "Content-Disposition",
    `attachment; filename="${downloadFilename()}"`
  );
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Cache-Control", "no-store, private");
  res.setHeader("Set-Cookie", `${COOKIE_NAME}=; ${cookieAttributes(selfPath, 0)}`);

  if (typeof upstream.size === "number" && upstream.size > 0) {
    res.setHeader("Content-Length", String(upstream.size));
  }

  Readable.fromWeb(upstream.stream).pipe(res);
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
