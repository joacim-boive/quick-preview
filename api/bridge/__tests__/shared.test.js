"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  entitlementStatusFromState,
  normalizeExpirationDate,
  parseCookieHeader,
  safeURL,
  signPayload,
  siteBaseURL,
  bridgePublicBaseURL,
  verifySignedPayload,
  applyCreateLinkCors,
  handleCreateLinkCorsPreflight,
} = require("../_shared");
const { createMockReq, createMockRes, withEnv } = require("./helpers");

describe("siteBaseURL", () => {
  it("uses QUICKPREVIEW_SITE_URL and strips trailing slash", () => {
    withEnv({ QUICKPREVIEW_SITE_URL: "https://boive.se/quick-preview/", VERCEL_URL: undefined }, () => {
      assert.equal(siteBaseURL(), "https://boive.se/quick-preview");
    });
  });

  it("falls back to default portal origin", () => {
    withEnv({ QUICKPREVIEW_SITE_URL: undefined, VERCEL_URL: undefined }, () => {
      assert.equal(siteBaseURL(), "https://boive.se/quick-preview");
    });
  });
});

describe("bridgePublicBaseURL", () => {
  it("uses QUICKPREVIEW_BRIDGE_PUBLIC_URL", () => {
    withEnv(
      {
        QUICKPREVIEW_BRIDGE_PUBLIC_URL: "https://quick-preview-alpha.vercel.app/",
        VERCEL_URL: undefined,
      },
      () => {
        assert.equal(bridgePublicBaseURL(), "https://quick-preview-alpha.vercel.app");
      }
    );
  });

  it("throws when neither bridge public URL nor VERCEL_URL is set", () => {
    withEnv(
      { QUICKPREVIEW_BRIDGE_PUBLIC_URL: undefined, VERCEL_URL: undefined },
      () => {
        assert.throws(() => bridgePublicBaseURL(), /QUICKPREVIEW_BRIDGE_PUBLIC_URL/);
      }
    );
  });
});

describe("safeURL", () => {
  it("joins relative portal paths under the site base", () => {
    withEnv({ QUICKPREVIEW_SITE_URL: "https://boive.se/quick-preview", VERCEL_URL: undefined }, () => {
      assert.equal(safeURL("pro/download/"), "https://boive.se/quick-preview/pro/download/");
    });
  });
});

describe("signPayload / verifySignedPayload", () => {
  it("round-trips a payload", () => {
    withEnv({ QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret" }, () => {
      const token = signPayload({ type: "appStoreLinkCode", email: "a@example.com" });
      assert.deepEqual(verifySignedPayload(token), {
        type: "appStoreLinkCode",
        email: "a@example.com",
      });
    });
  });

  it("rejects tampered signatures", () => {
    withEnv({ QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret" }, () => {
      const token = signPayload({ type: "appStoreLinkCode", email: "a@example.com" });
      const [payloadPart] = token.split(".");
      assert.throws(() => verifySignedPayload(`${payloadPart}.deadbeef`), /Signature mismatch/);
    });
  });
});

describe("entitlementStatusFromState", () => {
  it("maps active and grace states", () => {
    assert.equal(entitlementStatusFromState("trialActive"), "active");
    assert.equal(entitlementStatusFromState("subscriptionActive"), "active");
    assert.equal(entitlementStatusFromState("gracePeriod"), "gracePeriod");
    assert.equal(entitlementStatusFromState("offlineGracePeriod"), "gracePeriod");
    assert.equal(entitlementStatusFromState("billingRetry"), "gracePeriod");
  });

  it("maps terminal and unknown states", () => {
    assert.equal(entitlementStatusFromState("revoked"), "revoked");
    assert.equal(entitlementStatusFromState("refunded"), "revoked");
    assert.equal(entitlementStatusFromState("expired"), "expired");
    assert.equal(entitlementStatusFromState("notEntitled"), "unlinked");
  });
});

describe("normalizeExpirationDate", () => {
  it("accepts future ISO dates", () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    const parsed = normalizeExpirationDate(future);
    assert.equal(parsed.toISOString(), new Date(future).toISOString());
  });

  it("accepts millisecond timestamps in the future", () => {
    const ms = Date.now() + 120_000;
    assert.equal(normalizeExpirationDate(ms).getTime(), new Date(ms).getTime());
  });

  it("falls back for invalid input", () => {
    const before = Date.now();
    const parsed = normalizeExpirationDate("not-a-date");
    assert.ok(parsed.getTime() > before);
  });
});

describe("parseCookieHeader", () => {
  it("parses and decodes cookie values", () => {
    assert.deepEqual(parseCookieHeader("a=1; QuickPreviewProDl=hello%2Fworld"), {
      a: "1",
      QuickPreviewProDl: "hello/world",
    });
  });
});

describe("CORS helpers", () => {
  it("allows configured portal origins by default", () => {
    withEnv({ QUICKPREVIEW_ALLOWED_ORIGINS: undefined }, () => {
      const res = createMockRes();
      applyCreateLinkCors(createMockReq({ headers: { origin: "https://boive.se" } }), res);
      assert.equal(res.headers["access-control-allow-origin"], "https://boive.se");

      const resWww = createMockRes();
      applyCreateLinkCors(createMockReq({ headers: { origin: "https://www.boive.se" } }), resWww);
      assert.equal(resWww.headers["access-control-allow-origin"], "https://www.boive.se");
    });
  });

  it("ignores disallowed origins", () => {
    withEnv({ QUICKPREVIEW_ALLOWED_ORIGINS: "https://boive.se" }, () => {
      const res = createMockRes();
      applyCreateLinkCors(createMockReq({ headers: { origin: "https://evil.example" } }), res);
      assert.equal(res.headers["access-control-allow-origin"], undefined);
    });
  });

  it("handles OPTIONS preflight", () => {
    withEnv({ QUICKPREVIEW_ALLOWED_ORIGINS: "https://boive.se" }, () => {
      const res = createMockRes();
      const handled = handleCreateLinkCorsPreflight(
        createMockReq({ method: "OPTIONS", headers: { origin: "https://boive.se" } }),
        res
      );
      assert.equal(handled, true);
      assert.equal(res.statusCode, 204);
      assert.equal(res.ended, true);
    });
  });
});
