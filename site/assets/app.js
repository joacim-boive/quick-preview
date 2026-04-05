function bridgeCreateLinkURL() {
  const meta = document.querySelector('meta[name="qp-bridge-api-origin"]');
  const origin = meta?.getAttribute("content")?.trim().replace(/\/$/, "") ?? "";
  if (origin) {
    return `${origin}/api/bridge/create-link-code`;
  }
  return "/api/bridge/create-link-code";
}

const navToggle = document.querySelector("[data-nav-toggle]");
const siteNav = document.querySelector("[data-site-nav]");
const yearTarget = document.querySelector("[data-year]");
const createLinkForm = document.querySelector("[data-create-link-form]");
const linkStatus = document.querySelector("[data-link-status]");
const proSessionLink = document.querySelector("[data-pro-session-link]");
const proEmailTarget = document.querySelector("[data-pro-email]");
const proTokenStateTarget = document.querySelector("[data-download-token-state]");

if (yearTarget) {
  yearTarget.textContent = String(new Date().getFullYear());
}

if (navToggle && siteNav) {
  navToggle.addEventListener("click", () => {
    const isOpen = siteNav.getAttribute("data-open") === "true";
    siteNav.setAttribute("data-open", String(!isOpen));
    navToggle.setAttribute("aria-expanded", String(!isOpen));
  });

  siteNav.querySelectorAll("a").forEach((link) => {
    link.addEventListener("click", () => {
      siteNav.setAttribute("data-open", "false");
      navToggle.setAttribute("aria-expanded", "false");
    });
  });
}

if (createLinkForm instanceof HTMLFormElement) {
  createLinkForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    const formData = new FormData(createLinkForm);
    const email = String(formData.get("email") || "").trim();
    if (!email) {
      if (linkStatus) {
        linkStatus.textContent = "Enter the email address you want to use for QuickPreview PRO.";
      }
      return;
    }

    if (linkStatus) {
      linkStatus.textContent = "Creating a Mac App Store deep link...";
    }

    try {
      const response = await fetch(bridgeCreateLinkURL(), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ email }),
      });

      const result = await response.json();
      if (!response.ok) {
        throw new Error(result.error || "Could not create the link.");
      }

      if (linkStatus) {
        linkStatus.textContent =
          "The link is ready. If the Mac App Store edition is installed on this Mac, it should open now.";
      }

      window.location.href = result.appStoreDeepLink;
    } catch (error) {
      if (linkStatus) {
        linkStatus.textContent =
          error instanceof Error ? error.message : "Could not create the link.";
      }
    }
  });
}

if (proSessionLink) {
  const searchParams = new URLSearchParams(window.location.search);
  const token = searchParams.get("token");
  const email = searchParams.get("email");

  if (token) {
    const deepLinkURL = new URL("quickpreview-pro://pro-session");
    deepLinkURL.searchParams.set("token", token);
    if (email) {
      deepLinkURL.searchParams.set("email", email);
    }
    proSessionLink.setAttribute("href", deepLinkURL.toString());

    if (proEmailTarget) {
      proEmailTarget.textContent = email
        ? `Ready for ${email}. Open QuickPreview PRO to finish sign-in on this Mac.`
        : "A mirrored subscriber token is ready for QuickPreview PRO on this Mac.";
    }

    if (proTokenStateTarget) {
      proTokenStateTarget.textContent =
        "Your mirrored token is attached to this page. Use the button above after QuickPreview PRO is installed.";
    }
  } else {
    proSessionLink.setAttribute("aria-disabled", "true");
    proSessionLink.classList.add("button-disabled");

    if (proEmailTarget) {
      proEmailTarget.textContent =
        "No token is attached to this page yet. Start from the subscriber portal first.";
    }

    if (proTokenStateTarget) {
      proTokenStateTarget.textContent =
        "This page needs a token from the App Store linking flow before it can sign in QuickPreview PRO.";
    }
  }
}
