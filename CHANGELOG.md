# Changelog

All notable changes to this GitHub mirror template project should be documented in this file.

This project currently follows a simple human-maintained changelog style.

---

## [0.1.0] - 2026-04-16

First release-ready template pack milestone.

### Added

- Initial public-readonly GitHub mirror template pack structure
- Core documentation set:
  - `README.md`
  - `INSTALL.md`
  - `OPERATIONS.md`
  - `FAQ.md`
  - `BT-PANEL-DEPLOYMENT-v1.md`
  - `DEPLOY-CHECKLIST.md`
  - `DOMAIN-PLAN.md`
  - `TEMPLATE-VARIABLES.md`
  - `FINAL-HANDOFF.md`
- Template renderer: `render-from-base-domain.sh`
- Render validation helper: `validate-rendered-config.sh`
- Six-domain mirror layout:
  - hub
  - raw
  - gist
  - assets
  - archive
  - download
- Custom error-page structure for:
  - login/account/auth-disabled flows
  - readonly/write-blocked flows

### Changed

- Domain rendering model now supports both:
  - `nested`
  - `flat-siblings`
- Deployment docs updated to reflect real-world tested `flat-siblings` usage
- Nginx guidance updated to use:
  - `listen 443 ssl;`
  - `http2 on;`
  instead of legacy combined syntax
- Documentation unified around the project boundary:
  - public readonly only
  - no login
  - no OAuth
  - no private repositories
  - no write operations

### Fixed

- Synced deployment docs with actual tested deployment behavior
- Synced domain/variable docs with current renderer behavior
- Cleaned warning-prone Nginx guidance from docs
- Clarified redirect whitelist requirement in `http {}` scope
- Replaced bare 403/404 handling guidance with explicit custom-page guidance for blocked paths

### Notes

This milestone represents a **stage-complete delivery** for the current scope:

- core mirror behavior bounded to public readonly usage
- template and docs brought into alignment
- project ready for release packaging / publication polishing
