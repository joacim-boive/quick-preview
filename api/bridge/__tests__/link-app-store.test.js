"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const handler = require("../link-app-store");
const { signPayload, verifySignedPayload } = require("../_shared");
const { createMockReq, createMockRes, withEnv } = require("./helpers");

function activeLinkCode(email = "user@example.com") {
  return signPayload({
    type: "appStoreLinkCode",
    email,
    issuedAt: new Date().toISOString(),
  });
}

describe("link-app-store", () => {
  it("rejects non-POST methods", () => {
    const res = createMockRes();
    handler(createMockReq({ method: "GET" }), res);
    assert.equal(res.statusCode, 405);
  });

  it("requires a link code", () => {
    const res = createMockRes();
    handler(createMockReq({ body: {} }), res);
    assert.equal(res.statusCode, 400);
    assert.deepEqual(res.body, { error: "A valid link code is required." });
  });

  it("rejects inactive subscriptions", () => {
    withEnv({ QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret" }, () => {
      const res = createMockRes();
      handler(
        createMockReq({
          body: {
            linkCode: activeLinkCode(),
            entitlementState: "expired",
          },
        }),
        res
      );
      assert.equal(res.statusCode, 403);
      assert.match(res.body.error, /active QuickPreview subscription/);
    });
  });

  it("issues a PRO token and ticketed bridge download URL", () => {
    withEnv(
      {
        QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret",
        QUICKPREVIEW_BRIDGE_PUBLIC_URL: "https://quick-preview-alpha.vercel.app",
        VERCEL_URL: undefined,
      },
      () => {
        const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
        const res = createMockRes();
        handler(
          createMockReq({
            body: {
              linkCode: activeLinkCode("user@example.com"),
              bundleIdentifier: "com.jboive.quickpreview",
              productID: "quickpreview.pro.monthly",
              entitlementState: "subscriptionActive",
              expirationDate: expiresAt,
              originalTransactionID: "1",
              transactionID: "2",
            },
          }),
          res
        );

        assert.equal(res.statusCode, 200);
        assert.equal(res.body.status, "active");
        assert.equal(res.body.email, "user@example.com");
        assert.match(
          res.body.downloadURL,
          /^https:\/\/quick-preview-alpha\.vercel\.app\/api\/bridge\/pro-download\?t=/
        );

        const token = verifySignedPayload(res.body.proAccessToken);
        assert.equal(token.type, "proAccessToken");
        assert.equal(token.email, "user@example.com");
        assert.equal(token.status, "active");
      }
    );
  });
});
