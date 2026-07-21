"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const handler = require("../validate-pro");
const { signPayload } = require("../_shared");
const { createMockReq, createMockRes, withEnv } = require("./helpers");

describe("validate-pro", () => {
  it("rejects non-POST methods", () => {
    const res = createMockRes();
    handler(createMockReq({ method: "GET" }), res);
    assert.equal(res.statusCode, 405);
  });

  it("requires an access token", () => {
    const res = createMockRes();
    handler(createMockReq({ body: {} }), res);
    assert.equal(res.statusCode, 400);
    assert.deepEqual(res.body, { error: "A valid access token is required." });
  });

  it("rejects non-pro access tokens", () => {
    withEnv({ QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret" }, () => {
      const res = createMockRes();
      const accessToken = signPayload({ type: "appStoreLinkCode", email: "a@example.com" });
      handler(createMockReq({ body: { accessToken } }), res);
      assert.equal(res.statusCode, 400);
      assert.deepEqual(res.body, { error: "The access token is invalid." });
    });
  });

  it("returns active status for a valid future token", () => {
    withEnv({ QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret" }, () => {
      const expiresAt = new Date(Date.now() + 60_000).toISOString();
      const refreshAfter = new Date(Date.now() + 30_000).toISOString();
      const accessToken = signPayload({
        type: "proAccessToken",
        email: "user@example.com",
        status: "active",
        expiresAt,
        refreshAfter,
      });

      const res = createMockRes();
      handler(createMockReq({ body: { accessToken } }), res);

      assert.equal(res.statusCode, 200);
      assert.equal(res.body.status, "active");
      assert.equal(res.body.email, "user@example.com");
      assert.equal(res.body.expiresAt, new Date(expiresAt).toISOString());
      assert.equal(res.body.refreshAfter, refreshAfter);
    });
  });

  it("marks expired tokens as expired", () => {
    withEnv({ QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret" }, () => {
      const expiresAt = new Date(Date.now() - 60_000).toISOString();
      const accessToken = signPayload({
        type: "proAccessToken",
        email: "user@example.com",
        status: "active",
        expiresAt,
      });

      const res = createMockRes();
      handler(createMockReq({ body: { accessToken } }), res);

      assert.equal(res.statusCode, 200);
      assert.equal(res.body.status, "expired");
    });
  });
});
