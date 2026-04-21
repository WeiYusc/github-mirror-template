#!/usr/bin/env bash
set -euo pipefail

# Installer/status contract single source of truth.
# Docs and regression should converge on these enums.

INSTALLER_STATUS_PREFLIGHT_VALUES=(pending ok warn blocked)
INSTALLER_STATUS_GENERATOR_VALUES=(pending running success failed)
INSTALLER_STATUS_APPLY_PLAN_VALUES=(pending generated)
INSTALLER_STATUS_APPLY_DRY_RUN_VALUES=(not-requested running success failed skipped)
INSTALLER_STATUS_APPLY_EXECUTE_VALUES=(not-requested running success needs-attention blocked cancelled failed skipped)
INSTALLER_STATUS_REPAIR_VALUES=("" ok needs-attention blocked)
INSTALLER_STATUS_ROLLBACK_VALUES=("" ok needs-attention blocked)
INSTALLER_STATUS_FINAL_VALUES=(running blocked failed needs-attention cancelled success)

installer_status_values_var_name() {
  case "$1" in
    preflight) printf 'INSTALLER_STATUS_PREFLIGHT_VALUES' ;;
    generator) printf 'INSTALLER_STATUS_GENERATOR_VALUES' ;;
    apply_plan) printf 'INSTALLER_STATUS_APPLY_PLAN_VALUES' ;;
    apply_dry_run) printf 'INSTALLER_STATUS_APPLY_DRY_RUN_VALUES' ;;
    apply_execute) printf 'INSTALLER_STATUS_APPLY_EXECUTE_VALUES' ;;
    repair) printf 'INSTALLER_STATUS_REPAIR_VALUES' ;;
    rollback) printf 'INSTALLER_STATUS_ROLLBACK_VALUES' ;;
    final) printf 'INSTALLER_STATUS_FINAL_VALUES' ;;
    *)
      echo "[status-contracts] unknown status field: $1" >&2
      return 1
      ;;
  esac
}
