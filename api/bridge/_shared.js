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

  const parsed = new Date(expirationDate);
  if (Number.isNaN(parsed.getTime())) {
    return new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
  }

  return parsed;
}

module.exports = {
  decodeBody,
  entitlementStatusFromState,
  json,
  normalizeExpirationDate,
  safeURL,
  signPayload,
  verifySignedPayload,
};
