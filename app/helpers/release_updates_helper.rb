module ReleaseUpdatesHelper
  def release_timestamp(value)
    value.is_a?(Integer) ? Time.at(value).utc.iso8601 : "Unknown"
  rescue RangeError
    "Outside the supported date range"
  end
  def release_failure_message(code)
    return nil unless code
    messages = {
      "trusted_utc_required" => "Staging is waiting for a fresh signed UTC receipt. Ask the native operator to prepare this request.",
      "clock_anomaly" => "A clock anomaly is holding new staging. Ask the operator to verify UTC and the private clock authority.",
      "time_receipt_stale" => "The time receipt expired or belongs to another clock domain. Prepare a fresh challenge.",
      "trusted_utc_rollback" => "The supplied UTC is earlier than an established observation. Verify the independent time authority.",
      "manifest_expired" => "This release metadata expired. Obtain a newer signed manifest.",
      "manifest_replay" => "This sequence was already reserved by another request. Resume the original request or obtain newer metadata.",
      "unknown_publisher" => "This publisher is not trusted. An operator must review publisher provenance and trust policy.",
      "revoked_publisher" => "This signing key was revoked. Obtain a release from a currently trusted publisher.",
      "package_digest" => "Package bytes are incomplete or changed. Ask the operator to obtain the exact signed package.",
      "disk_capacity" => "Staging stopped at the disk-capacity guard. Free capacity and resume the original request.",
      "host_disk_capacity" => "The host disk-capacity guard stopped staging. Check host capacity before resuming.",
      "request_cancelled" => "This request was cancelled. Staged evidence remains isolated; no running release changed.",
      "native_approval_required" => "The native operator must explicitly approve this exact request before any host action.",
      "stale_host_generation" => "Another native operation changed the release generation. Reload and submit a fresh request.",
      "restore_drill_unqualified" => "A successful disposable restore rehearsal has not been established.",
      "snapshot_required" => "A verified recovery point is required before promotion.",
      "snapshot_integrity" => "Recovery snapshot integrity failed. Create and verify a new recovery point.",
      "restore_loss_window_not_accepted" => "The current data-loss window was not explicitly accepted. No restore was started.",
      "candidate_continuity" => "Candidate content, theme or credential authority differs from the current site. Traffic was not authorized to switch.",
      "theme_continuity" => "The release does not preserve every installed theme identity. Obtain a compatible package."
    }
    return messages[code] if messages.key?(code)
    return "Compatibility checks refused this release. Review the declared requirements and ask the operator for a compatible package." if code.start_with?("incompatible_", "database_", "unsupported_host", "prior_release", "locked_rails")
    "Native operation stopped. Review the verified status and ask the operator to inspect the private journal before continuing."
  end
end
