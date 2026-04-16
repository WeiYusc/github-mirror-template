# RELEASE-NOTES.md

GitHub Mirror Template Pack - Release Notes / Disclaimer

---

# 1. What this project is

This project is a **GitHub public-readonly mirror template pack** intended for:

- public repository browsing
- raw file access
- gist readonly access
- archive / release download proxying
- Nginx/BT-Panel based deployment experiments and controlled rollouts

It is designed around **risk-bounded readonly mirroring**, not full GitHub feature replication.

---

# 2. What this project is NOT

This project is not:

- an official GitHub product
- a full GitHub clone
- a private repository access gateway
- an account/session proxy
- a write-capable GitHub frontend

It does **not** support:

- login
- OAuth
- private repositories
- account settings
- notifications
- star / fork / issue creation / PR creation / push
- PAT / token / SSH credential proxying

---

# 3. Intended deployment posture

This template is intended to be deployed in a **careful, incremental, reviewable** way:

- add new mirror domains
- do not overwrite existing production site configs
- back up first
- write configs to disk first
- run `nginx -t`
- reload only after syntax passes
- verify with smoke tests

It is **not** intended as a blind one-click installer.

---

# 4. Operational responsibility

Anyone deploying this project is responsible for:

- domain ownership / DNS correctness
- TLS certificate management
- Nginx include/layout correctness
- legal/compliance review for their environment
- acceptable-use / rate / abuse considerations
- monitoring, rollback, and incident handling

---

# 5. Security boundary

The design goal is to stay inside a safer boundary:

- public readonly only
- method restriction to safe reads
- blocked handling for login/account-sensitive paths
- blocked handling for readonly-incompatible write paths
- redirect allowlisting for archive/download flows

If you expand this project beyond that boundary, you are changing its risk profile.

---

# 6. No warranty

This project is provided as a template/reference implementation.

No guarantee is made that it will:

- perfectly reproduce GitHub behavior
- remain compatible with upstream changes forever
- satisfy legal/compliance requirements in your jurisdiction
- work unchanged in all Nginx / BT-Panel environments

You are expected to review, test, and adapt it before production use.

---

# 7. Suggested release positioning

If publishing this repository publicly, a safe positioning is:

> A bounded, public-readonly GitHub mirror template pack for Nginx / BT-Panel deployments, focused on incremental rollout, explicit safety boundaries, and operator reviewability.
