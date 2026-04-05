const {
  applyCreateLinkCors,
  decodeBody,
  handleCreateLinkCorsPreflight,
  safeURL,
  signPayload,
} = require("./_shared");

module.exports = function handler(req, res) {
  if (handleCreateLinkCorsPreflight(req, res)) {
    return;
  }
  applyCreateLinkCors(req, res);

  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed." });
    return;
  }

  try {
    const { email } = decodeBody(req);
    if (!email || typeof email !== "string") {
      res.status(400).json({ error: "Email is required." });
      return;
    }

    const linkCode = signPayload({
      type: "appStoreLinkCode",
      email: email.trim(),
      issuedAt: new Date().toISOString(),
    });

    res.status(200).json({
      email: email.trim(),
      linkCode,
      appStoreDeepLink: `quickpreview://account-link?code=${encodeURIComponent(linkCode)}&email=${encodeURIComponent(email.trim())}`,
      downloadURL: safeURL("/pro/download/"),
    });
  } catch (error) {
    res.status(500).json({
      error:
        error instanceof Error
          ? error.message
          : "Could not create a link code.",
    });
  }
};
