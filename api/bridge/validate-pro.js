const { normalizeExpirationDate, verifySignedPayload } = require("./_shared");

module.exports = function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed." });
    return;
  }

  try {
    const body = typeof req.body === "string" ? JSON.parse(req.body) : req.body || {};
    const { accessToken } = body;

    if (!accessToken || typeof accessToken !== "string") {
      res.status(400).json({ error: "A valid access token is required." });
      return;
    }

    const tokenPayload = verifySignedPayload(accessToken);
    if (tokenPayload.type !== "proAccessToken") {
      res.status(400).json({ error: "The access token is invalid." });
      return;
    }

    const expiresAt = normalizeExpirationDate(tokenPayload.expiresAt);
    let status = tokenPayload.status || "unlinked";
    if (expiresAt.getTime() < Date.now()) {
      status = "expired";
    }

    res.status(200).json({
      status,
      email: tokenPayload.email || null,
      expiresAt: expiresAt.toISOString(),
      refreshAfter: tokenPayload.refreshAfter || new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
    });
  } catch (error) {
    res.status(500).json({ error: error instanceof Error ? error.message : "Could not validate QuickPreview PRO access." });
  }
};
