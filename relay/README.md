# Sims Mod Helper relay

Setup, once:

1. Make a new Google Sheet. Name it whatever you like; the tab is created for you.
2. In the Sheet: Extensions → Apps Script.
3. Delete the sample code, paste all of `Code.gs`, save.
4. Project Settings → Script Properties → add two properties:
   - `AGENT_TOKEN`: a long random string (40+ characters)
   - `INSTALLER_TOKEN`: a different long random string
   Keep both; the agent and the installer each need their own.
5. Deploy → New deployment → Web app.
   - Execute as: **Me**
   - Who has access: **Anyone**
6. Copy the web-app URL. That URL plus a token is the whole API.

Access is "Anyone" on purpose: callers prove themselves with the tokens, not with
Google accounts. The script only ever touches this one Sheet, and the tokens are
the only way in, so keep them secret and rotate them by editing the properties.

Check it works: send a POST with `{"token":"<INSTALLER_TOKEN>","action":"pending"}`
and expect `{"ok":true,"rows":[]}`. A wrong token gets `{"ok":false,"error":"not allowed"}`.

Tests run on plain Node, no packages: `node test/relay.test.js`.
