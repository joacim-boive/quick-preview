"use strict";

const { describe, it, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const { signPayload } = require("../_shared");
const { createMockReq, createMockRes, withEnv } = require("./helpers");

const blobModulePath = require.resolve("@vercel/blob");
const handlerModulePath = require.resolve("../pro-download");
const sharedModulePath = require.resolve("../_shared");

function loadHandler(getImpl) {
  delete require.cache[blobModulePath];
  delete require.cache[handlerModulePath];
  delete require.cache[sharedModulePath];

  require.cache[blobModulePath] = {
    id: blobModulePath,
    filename: blobModulePath,
    loaded: true,
    exports: {
      get: getImpl,
    },
  };

  return require("../pro-download");
}

function restoreModules() {
  delete require.cache[blobModulePath];
  delete require.cache[handlerModulePath];
  delete require.cache[sharedModulePath];
}

describe("pro-download", () => {
  beforeEach(() => {
    restoreModules();
  });

  afterEach(() => {
    restoreModules();
  });

  it("rejects non-GET methods", async () => {
    const handler = loadHandler(async () => ({ stream: null }));
    const res = createMockRes();
    await handler(createMockReq({ method: "POST" }), res);
    assert.equal(res.statusCode, 405);
  });

  it("rejects invalid tickets", async () => {
    withEnv(
      {
        QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret",
        QUICKPREVIEW_BRIDGE_PUBLIC_URL: "https://quick-preview-alpha.vercel.app",
      },
      async () => {
        const handler = loadHandler(async () => ({ stream: null }));
        const res = createMockRes();
        await handler(createMockReq({ method: "GET", query: { t: "bad.token" } }), res);
        assert.equal(res.statusCode, 500);
      }
    );
  });

  it("rejects expired tickets", async () => {
    withEnv(
      {
        QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret",
        QUICKPREVIEW_BRIDGE_PUBLIC_URL: "https://quick-preview-alpha.vercel.app",
      },
      async () => {
        const handler = loadHandler(async () => ({ stream: null }));
        const ticket = signPayload({
          type: "proDownloadTicket",
          proAccessToken: "token",
          email: "user@example.com",
          exp: new Date(Date.now() - 1000).toISOString(),
        });
        const res = createMockRes();
        await handler(createMockReq({ method: "GET", query: { t: ticket } }), res);
        assert.equal(res.statusCode, 400);
        assert.match(String(res.body), /expired/i);
      }
    );
  });

  it("sets a session cookie and redirects for a valid ticket", async () => {
    withEnv(
      {
        QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret",
        QUICKPREVIEW_BRIDGE_PUBLIC_URL: "https://quick-preview-alpha.vercel.app",
      },
      async () => {
        const handler = loadHandler(async () => ({ stream: null }));
        const ticket = signPayload({
          type: "proDownloadTicket",
          proAccessToken: "token",
          email: "user@example.com",
          exp: new Date(Date.now() + 60_000).toISOString(),
        });
        const res = createMockRes();
        await handler(createMockReq({ method: "GET", query: { t: ticket } }), res);

        assert.equal(res.statusCode, 302);
        assert.equal(res.headers.location, "https://quick-preview-alpha.vercel.app/api/bridge/pro-download");
        assert.match(String(res.headers["set-cookie"]), /QuickPreviewProDl=/);
      }
    );
  });

  it("returns a portal HTML page when no session cookie is present", async () => {
    withEnv(
      {
        QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret",
        QUICKPREVIEW_BRIDGE_PUBLIC_URL: "https://quick-preview-alpha.vercel.app",
        QUICKPREVIEW_SITE_URL: "https://boive.se/quick-preview",
        VERCEL_URL: undefined,
      },
      async () => {
        const handler = loadHandler(async () => ({ stream: null }));
        const res = createMockRes();
        await handler(createMockReq({ method: "GET", headers: {}, query: {} }), res);
        assert.equal(res.statusCode, 403);
        assert.match(String(res.body), /https:\/\/boive\.se\/quick-preview\/pro\//);
      }
    );
  });

  it("uses a valid session cookie before fetching the private blob", async () => {
    await withEnv(
      {
        QUICKPREVIEW_BRIDGE_SECRET: "unit-test-secret",
        QUICKPREVIEW_BRIDGE_PUBLIC_URL: "https://quick-preview-alpha.vercel.app",
        QUICKPREVIEW_PRO_BLOB_PATHNAME: "downloads/QuickPreviewPro.dmg",
      },
      async () => {
        let requestedPath;
        const handler = loadHandler(async (pathname) => {
          requestedPath = pathname;
          throw new Error("blob offline");
        });

        const session = signPayload({
          type: "proDownloadSession",
          proAccessToken: "token",
          email: "user@example.com",
          exp: new Date(Date.now() + 60_000).toISOString(),
        });

        const res = createMockRes();
        await handler(
          createMockReq({
            method: "GET",
            headers: { cookie: `QuickPreviewProDl=${encodeURIComponent(session)}` },
            query: {},
          }),
          res
        );

        assert.equal(requestedPath, "downloads/QuickPreviewPro.dmg");
        assert.equal(res.statusCode, 500);
        assert.match(String(res.body), /blob offline/);
      }
    );
  });
});
