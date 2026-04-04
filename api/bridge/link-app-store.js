const {
  decodeBody,
  entitlementStatusFromState,
  normalizeExpirationDate,
  safeURL,
  signPayload,
  verifySignedPayload,
} = require("./_shared");

module.exports = function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed." });
    return;
  }

  try {
    const body = decodeBody(req);
    const { linkCode, bundleIdentifier, productID, entitlementState, expirationDate, originalTransactionID, transactionID } = body;

    if (!linkCode || typeof linkCode !== "string") {
      res.status(400).json({ error: "A valid link code is required." });
      return;
    }

    const linkPayload = verifySignedPayload(linkCode);
    if (linkPayload.type !== "appStoreLinkCode" || !linkPayload.email) {
      res.status(400).json({ error: "The link code is invalid." });
      return;
    }

    const status = entitlementStatusFromState(entitlementState);
    if (status === "unlinked" || status === "expired" || status === "revoked") {
      res.status(403).json({ error: "An active QuickPreview subscription is required before unlocking QuickPreview PRO." });
      return;
    }

    const expiresAt = normalizeExpirationDate(expirationDate);
    const refreshAfter = new Date(Math.min(expiresAt.getTime(), Date.now() + 24 * 60 * 60 * 1000));
    const proAccessToken = signPayload({
      type: "proAccessToken",
      email: linkPayload.email,
      status,
      productID,
      bundleIdentifier,
      originalTransactionID: originalTransactionID || null,
      transactionID: transactionID || null,
      issuedAt: new Date().toISOString(),
      expiresAt: expiresAt.toISOString(),
      refreshAfter: refreshAfter.toISOString(),
    });

    res.status(200).json({
      status,
      email: linkPayload.email,
      proAccessToken,
      expiresAt: expiresAt.toISOString(),
      downloadURL: safeURL("/pro/download/", {
        token: proAccessToken,
        email: linkPayload.email,
      }),
    });
  } catch (error) {
    res.status(500).json({ error: error instanceof Error ? error.message : "Could not link the App Store subscription." });
  }
};
