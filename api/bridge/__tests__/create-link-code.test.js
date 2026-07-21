"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const handler = require("../create-link-code");
const { verifySignedPayload } = require("../_shared");
const { createMockReq, createMockRes, withEnv } = require("./helpers");

describe("create-link-code", () => {
  it("rejects non-POST methods", () => {
    const res = createMockRes();
    handler(createMockReq({ method: "GET" }), res);
    assert.equal(res.statusCode, 405);
    assert.deepEqual(res.body, { error: "Method not allowed." });
  });

  it("requires an email", () => {
    const res = createMockRes();
    handler(createMockReq({ body: {} }), res);
    assert.equal(res.statusCode, 400);
    assert.deepEqual(res.body, { error: "Email is required." });
  });

  it("returns a signed link code and portal download URL", () => {
    withEnv(
      {
        QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret",
        QUICKPREVIEW_SITE_URL: "https://boive.se/quick-preview",
        QUICKPREVIEW_ALLOWED_ORIGINS: "https://boive.se",
        VERCEL_URL: undefined,
      },
      () => {
        const res = createMockRes();
        handler(
          createMockReq({
            body: { email: "  user@example.com " },
            headers: { origin: "https://boive.se" },
          }),
          res
        );

        assert.equal(res.statusCode, 200);
        assert.equal(res.headers["access-control-allow-origin"], "https://boive.se");
        assert.equal(res.body.email, "user@example.com");
        assert.equal(res.body.downloadURL, "https://boive.se/quick-preview/pro/download/");
        assert.match(res.body.appStoreDeepLink, /^quickpreview:\/\/account-link\?/);

        const payload = verifySignedPayload(res.body.linkCode);
        assert.equal(payload.type, "appStoreLinkCode");
        assert.equal(payload.email, "user@example.com");
      }
    );
  });
});
