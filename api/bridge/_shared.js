const { createHmac, timingSafeEqual } = require("node:crypto");

const DEFAULT_SECRET = "quickpreview-dev-bridge-secret";

function bridgeSecret() {
  return process.env.QUICKPREVIEW_BRIDGE_SECRET || DEFAULT_SECRET;
}

function json(response, status = 200) {
  return {
    statusCode: status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
    body: JSON.stringify(response),
  };
}

function decodeBody(req) {
  if (!req.body) {
    return {};
  }

  if (typeof req.body === "string") {
    return JSON.parse(req.body);
  }

  return req.body;
}

function signPayload(payload) {
  const jsonPayload = JSON.stringify(payload);
  const payloadPart = Buffer.from(jsonPayload, "utf8").toString("base64url");
  const signature = createHmac("sha256", bridgeSecret())
    .update(payloadPart)
    .digest("base64url");
  return `${payloadPart}.${signature}`;
}

function verifySignedPayload(token) {
  if (!token || typeof token !== "string" || !token.includes(".")) {
    throw new Error("Invalid token.");
  }

  const [payloadPart, signature] = token.split(".");
  const expectedSignature = createHmac("sha256", bridgeSecret())
    .update(payloadPart)
    .digest("base64url");

  const providedBuffer = Buffer.from(signature, "utf8");
  const expectedBuffer = Buffer.from(expectedSignature, "utf8");
  if (
    providedBuffer.length !== expectedBuffer.length ||
    !timingSafeEqual(providedBuffer, expectedBuffer)
  ) {
    throw new Error("Signature mismatch.");
  }

  const payloadJSON = Buffer.from(payloadPart, "base64url").toString("utf8");
  return JSON.parse(payloadJSON);
}

function siteBaseURL() {
  const explicit = process.env.QUICKPREVIEW_SITE_URL;
  if (explicit && String(explicit).trim()) {
    return String(explicit).replace(/\/$/, "");
  }
  const vercel = process.env.VERCEL_URL;
  if (vercel && String(vercel).trim()) {
    const host = String(vercel).replace(/^https?:\/\//i, "");
    return `https://${host}`;
  }
  return "https://quickpreview.boive.se";
}

/**
 * Public origin for ticketed bridge URLs (`/api/bridge/pro-download`). Must be a host that actually runs these
 * serverless routes — never the static marketing site (e.g. boive.se), or ticket links 404 and clients may fall back to unsafe patterns.
 */
function bridgePublicBaseURL() {
  const explicit = process.env.QUICKPREVIEW_BRIDGE_PUBLIC_URL;
  if (explicit && String(explicit).trim()) {
    return String(explicit).replace(/\/$/, "");
  }
  const vercel = process.env.VERCEL_URL;
  if (vercel && String(vercel).trim()) {
    const host = String(vercel).replace(/^https?:\/\//i, "");
    return `https://${host}`;
  }
  throw new Error(
    "Set QUICKPREVIEW_BRIDGE_PUBLIC_URL on Vercel (e.g. https://quick-preview-alpha.vercel.app). VERCEL_URL was missing and marketing siteBaseURL() must not be used for bridge tickets."
  );
}

function parseCookieHeader(header) {
  const out = {};
  if (!header || typeof header !== "string") {
    return out;
  }
  for (const part of header.split(";")) {
    const idx = part.indexOf("=");
    if (idx === -1) {
      continue;
    }
    const key = part.slice(0, idx).trim();
    let value = part.slice(idx + 1).trim();
    try {
      value = decodeURIComponent(value);
    } catch {
      // keep raw
    }
    out[key] = value;
  }
  return out;
}

function safeURL(pathname, query = {}) {
  const url = new URL(pathname, `${siteBaseURL()}/`);

  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== null && value !== "") {
      url.searchParams.set(key, String(value));
    }
  }

  return url.toString();
}

function entitlementStatusFromState(entitlementState) {
  switch (entitlementState) {
    case "trialActive":
    case "subscriptionActive":
      return "active";
    case "gracePeriod":
    case "offlineGracePeriod":
    case "billingRetry":
      return "gracePeriod";
    case "revoked":
    case "refunded":
      return "revoked";
    case "expired":
      return "expired";
    default:
      return "unlinked";
  }
}

function normalizeExpirationDate(expirationDate) {
  if (!expirationDate) {
    return new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
  }

  if (typeof expirationDate === "number" && Number.isFinite(expirationDate)) {
    // Older clients may send numeric timestamps. Accept:
    // - milliseconds since Unix epoch
    // - seconds since Unix epoch
    // - seconds since Apple's 2001 reference date
    const candidates = [
      new Date(expirationDate),
      new Date(expirationDate * 1000),
      new Date((expirationDate + 978307200) * 1000),
    ];
    const parsedCandidate = candidates.find(
      (candidate) => !Number.isNaN(candidate.getTime()) && candidate.getTime() > Date.now()
    );
    if (parsedCandidate) {
      return parsedCandidate;
    }
  }

  const parsed = new Date(expirationDate);
  if (Number.isNaN(parsed.getTime())) {
    return new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
  }

  return parsed;
}

function parseAllowedBrowserOrigins() {
  const raw =
    process.env.QUICKPREVIEW_ALLOWED_ORIGINS || "https://quickpreview.boive.se";
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

function applyCreateLinkCors(req, res) {
  const allowed = parseAllowedBrowserOrigins();
  const origin = req.headers.origin;
  if (origin && allowed.includes(origin)) {
    res.setHeader("Access-Control-Allow-Origin", origin);
    res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");
    res.setHeader("Vary", "Origin");
  }
}

function handleCreateLinkCorsPreflight(req, res) {
  if (req.method !== "OPTIONS") {
    return false;
  }
  applyCreateLinkCors(req, res);
  res.status(204).end();
  return true;
}

module.exports = {
  applyCreateLinkCors,
  bridgePublicBaseURL,
  decodeBody,
  entitlementStatusFromState,
  handleCreateLinkCorsPreflight,
  json,
  normalizeExpirationDate,
  parseCookieHeader,
  safeURL,
  signPayload,
  siteBaseURL,
  verifySignedPayload,
};
