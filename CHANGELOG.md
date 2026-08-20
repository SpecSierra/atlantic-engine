# Changelog

User-facing release notes for Atlantic Browser. Versions are set by
`ATLANTIC_BROWSER_VERSION` in `versions.env`; the engine version moves
independently and is noted under Housekeeping.

Release 1.1.0 – 20/08/2026 :

Browsing

Opening a link from another app now loads that link when Atlantic was not already running, instead of starting the browser on an empty tab.
Choosing an address from the URL bar's history list now works even when it is the page you had just navigated away from.
"Close all tabs on exit" now takes effect — the setting was saved but nothing ever acted on it.

Search

A website that offers its own search engine can now be added from Settings → Search with. Nothing could reach that screen before, so no site's search could be installed.
An engine offered by a page opened before you visit Settings is no longer lost — restored tabs and links handed over by another app now count.

Display

Going Back now shows the page you are returning to while it reloads, instead of leaving the previous page on screen for several seconds while the address bar already shows the new one.

Downloads

The save destination setting is now honoured: files go straight to your chosen folder, and when you are asked where to put a file the dialog starts in that folder rather than the default one.
Downloading the same file twice no longer overwrites the first copy when saving automatically.

Housekeeping

Web engine (WPE WebKit) 2.52.5 → 2.52.6.
CPU and GPU tuning moved out into a separate sfos-qcom-boost package. Two copies of the same tuning could previously run at the same time and leave the fast CPU cores pinned at maximum. Installing from OpenRepos pulls the new package in automatically; the zypper repo does not carry it.

Release 1.0.0 – 18/08/2026 :

Browsing

Tapping the address bar now keeps the whole address selected, so typing replaces it instead of dropping the cursor mid-text.
"Start browser in private browsing mode" now works — the setting was saved but ignored at launch.

Display

Pinch-to-zoom now zooms the page properly, so text stays sharp instead of looking like a magnified screenshot.
Tabs, history, bookmarks and saved logins now show each site's own icon.

Passwords

The vault refuses to save credentials it cannot properly encrypt, rather than storing them unprotected.
Autofill matches saved logins to the right site more reliably, and pages can no longer reach into the autofill mechanism.

Housekeeping

Cookie-banner rules (DuckDuckGo autoconsent) 16.10.0 → 16.23.0.
Ad-blocking engine (Brave adblock-rust) 0.12.5 → 0.13.2.
AVIF image support (libavif) 1.0.4 → 1.4.2.
Sandbox runtime (bubblewrap) 0.11.0 → 0.11.2
