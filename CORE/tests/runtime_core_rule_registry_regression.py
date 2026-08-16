from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from core_rule_registry import REQUIRED_RULE_IDS, canonical_hash, load_registry, public_projection


def clone(value: object) -> object:
    return json.loads(json.dumps(value, ensure_ascii=False))


def sign(value: dict[str, object]) -> dict[str, object]:
    result = clone(value)
    assert isinstance(result, dict)
    result["payloadHash"] = canonical_hash({key: item for key, item in result.items() if key != "payloadHash"})
    return result


def write_fixture(root: Path, registry: dict[str, object] | bytes, manifest: dict[str, object]) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8", newline="\n")
    path = root / "super-brain-rules.json"
    if isinstance(registry, bytes):
        path.write_bytes(registry)
    else:
        path.write_text(json.dumps(registry, ensure_ascii=False), encoding="utf-8", newline="\n")


def assert_r6_continuation_policy_docs() -> None:
    """Keep the same-workline visible-first selector contract consistent."""

    skill = (ROOT / "super-memory-brain" / "SKILL.md").read_text(encoding="utf-8")
    recovery = (ROOT / "references" / "status-recovery.md").read_text(encoding="utf-8")
    turn_runtime = (ROOT / "runtime" / "turn_runtime.py").read_text(encoding="utf-8")
    host_bridge = (ROOT / "runtime" / "host_continuation_bridge.py").read_text(encoding="utf-8")
    for marker in (
        "Every same-workline continuation is visible-context-first",
        "resume\n**locator**",
        "same-scope task/workline",
        "current_visible_assistant",
        "latest_durable_assistant",
        "latest_assistant",
        "display-only readback",
        "pause followed by continue",
        "host-derived observation",
        "to another approved workline",
        "visibleProgressReceipt.payloadHash",
        "read_thread(turnLimit=1",
        "current observation cannot be supplied",
        "first three non-empty",
        "host-derived observation",
        "Auto-alignment is an emergency-only drift repair",
        "H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED",
        "never writes, realigns, or promotes",
        "exact current visible-tail sentence",
        "display-only continuity evidence",
        "CAS-rebind one unique",
        "hot index and activation receipt",
        "transient H7 receipt binding",
        "A timeout, skipped read, slow",
    ):
        assert marker in skill, marker
    for marker in (
        "Visible-First, Mapping-Second Continuation",
        "time-latest real assistant reply still visible",
        "Two-Stage Resume Decision",
        "same-scope task/workline",
        "current_visible_assistant",
        "latest_durable_assistant",
        "latest_assistant",
        "display-only continuity evidence",
        "transient H7 receipt binding",
        "pause-after-continue",
        "another approved workline",
        "[H7-PROGRESS-V4 receipt_hash=<64 lowercase hex characters>]",
        "one `turnLimit=2` retry",
        "first three non-empty lines",
        "Host cannot provide a current observation",
        "Automatic alignment is an emergency-only guard",
        "H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED",
        "never writes, realigns, or promotes",
        "current visible locator",
        "Strict v4 validation is required for a durable progress/phase/completion claim",
        "plain current reply remains\ndisplay-only continuity evidence",
        "Host-read-back user\nstage receipt",
        "package/runtime identity and rule-registry hash",
        "H7_RUNTIME_UNAVAILABLE",
        "timeout never proves that",
        "never the normal route",
    ):
        assert marker in recovery, marker
    for retired in (
        "Current visible context wins.",
        "or a clearly labeled summary when only a checkpoint is",
        "its first non-empty line is exactly `G1`, followed by the one compact progress",
        "auto-finalizes it before continuation",
        "It may preserve exactly the observed sentence",
        "It may preserve one exact\nobserved sentence",
    ):
        assert retired not in recovery + skill, retired
    assert "Validate the emergency drift fallback without mutating H7 state." in turn_runtime
    assert 'return None, "H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED"' in turn_runtime
    assert "HOST_VISIBLE_TAIL_READ_TIMEOUT_SECONDS = 5.0" in host_bridge
    assert "HOST_VISIBLE_TAIL_MAX_NONEMPTY_LINES = 3" in host_bridge
    assert "attempts = (1, 2)" in host_bridge
    assert 'return None, "HOST_VISIBLE_TAIL_READ_DEADLINE_EXCEEDED"' in host_bridge
    assert "acquire_current_visible_assertion" in host_bridge
    assert "transportMayStillRun" in host_bridge
    assert "H7_EXTERNAL_CONTINUATION_STATE_FORBIDDEN" in turn_runtime
    assert "from continuation_capsule import" not in turn_runtime
    assert "H7_CONTINUATION_CAPSULE_" not in turn_runtime
    assert not (ROOT / "runtime" / "continuation_capsule.py").exists()
    assert '"continuation_capsule": {' not in (ROOT / "runtime" / "brain_mcp.py").read_text(encoding="utf-8")
    assert "continuation-capsule" not in (ROOT / "runtime" / "brain_cli.py").read_text(encoding="utf-8")


def main() -> int:
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    source = json.loads((ROOT / "super-brain-rules.json").read_text(encoding="utf-8"))
    assert_r6_continuation_policy_docs()
    current = load_registry(ROOT, manifest=manifest)
    assert current["status"] == "current", current
    assert current["code"] == "CORE_RULE_REGISTRY_CURRENT", current
    assert {rule["ruleId"] for rule in current["rules"]} == set(REQUIRED_RULE_IDS), current
    assert current["payloadHash"] == canonical_hash({key: value for key, value in source.items() if key != "payloadHash"})
    assert current["registryVersion"] == 57, current
    project_knowledge_rule = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-ON-DEMAND-PROJECT-KNOWLEDGE-001")
    assert project_knowledge_rule["entrypoint"] == "runtime/project_knowledge.py", project_knowledge_rule
    assert set(project_knowledge_rule["acceptanceTests"]) >= {
        "project_knowledge_proof_bound_slice_replay",
        "project_knowledge_path_hash_and_symlink_fail_closed_replay",
        "project_knowledge_no_full_tree_scan_replay",
        "project_knowledge_receipt_telemetry_evidence_consistency_replay",
        "ordinary_continuation_no_project_scan_replay",
    }, project_knowledge_rule
    h7 = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-H7-ACTIVATION-001")
    assert h7["revision"] == 7, h7
    assert h7["effect"] == "run_h7_mcp_or_same_h7_cli_identity_and_proof_validation_in_background_for_ordinary_continuation_without_creating_or_requiring_task_card_require_current_h7_identity_scope_proof_and_derived_index_rebuild_before_formal_stage_high_impact_action_durable_learning_or_runtime_identity_repair_use_one_package_local_writable_activation_receipt_root_and_treat_p7_hook_and_legacy_host_receipt_junctions_as_fail_open_historical_compatibility_only_without_install_repair_authorization_or_evidence", h7
    assert h7["entrypoint"] == "runtime/turn_runtime.py", h7
    assert set(h7["trigger"]) >= {
        "normal_operation",
        "maintenance",
        "stage_complete",
        "stage_acceptance",
        "learning",
        "p7",
        "hook",
        "hook_reinstall",
        "hook_repair",
    }, h7
    assert set(h7["acceptanceTests"]) >= {
        "activation_registry_binding",
        "stale_registry_withheld",
        "stale_mcp_cli_preference_replay",
        "h7_cli_equivalent_transport_replay",
        "h7_dual_transport_unavailable_withheld",
        "no_governed_direct_downgrade_replay",
        "normal_h7_transport_only_replay",
        "maintenance_h7_transport_only_replay",
        "stage_acceptance_h7_transport_only_replay",
        "learning_h7_transport_only_replay",
        "p7_hook_fail_open_compatibility_only_replay",
        "p7_hook_reinstall_denial_replay",
        "p7_hook_repair_denial_replay",
        "p7_hook_authorization_denial_replay",
        "p7_hook_progress_evidence_denial_replay",
        "p7_hook_acceptance_evidence_denial_replay",
        "p7_hook_learning_evidence_denial_replay",
        "h7_package_local_activation_receipt_replay",
        "hot_update_same_h7_cli_repair_replay",
        "hot_update_identity_scope_proof_rebind_replay",
        "hot_update_activation_rebuild_replay",
        "background_h7_validation_nonblocking_ordinary_no_task_replay",
        "h7_validation_required_for_stage_high_impact_and_durable_learning_replay",
    }, h7
    control_plane = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-INDEPENDENT-CONTROL-PLANE-AGENT-001")
    assert control_plane["revision"] == 2, control_plane
    assert control_plane["priority"] == 119, control_plane
    assert control_plane["scope"] == "runtime", control_plane
    assert control_plane["effect"] == "operate_super_brain_as_independent_control_plane_agent_with_native_super_brain_identity_role_separated_user_execution_progress_fact_behavior_authorities_and_non_authorizing_host_adapters_memory_capabilities_and_collaborator_agents", control_plane
    assert control_plane["entrypoint"] == "runtime/brain_core.py", control_plane
    assert set(control_plane["acceptanceTests"]) >= {
        "agent_identity_status_projection_replay",
        "agent_identity_turn_receipt_projection_replay",
        "authority_role_separation_replay",
        "host_adapter_non_authorizing_replay",
        "collaborator_agent_non_authorizing_replay",
        "native_super_brain_identity_projection_replay",
        "host_platform_metadata_non_authorizing_replay",
    }, control_plane
    maintainability = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-CONTROL-PLANE-MAINTAINABILITY-001")
    assert maintainability["revision"] == 10, maintainability
    assert maintainability["effect"] == "preserve_one_small_single_authoritative_continuation_control_plane_with_one_bounded_host_derived_visible_observation_then_same_scope_task_and_live_project_mapping_one_ordinary_no_task_path_one_drift_repair_path_and_one_state_card_selector_limited_to_proven_context_unavailable_or_verified_parent_return_remove_dead_conflicting_duplicate_or_cache_lease_routes_avoid_extra_mcp_processes_avoid_unnecessary_architectural_sprawl_remove_unnecessary_code_only_after_scoped_impact_audit_preserve_required_contracts_and_require_each_retained_branch_to_have_one_named_invariant_and_one_regression", maintainability
    assert set(maintainability["acceptanceTests"]) >= {
        "single_normal_control_plane_path_replay",
        "no_same_workline_state_card_bypass_replay",
        "three_selector_control_plane_inventory_replay",
        "no_old_state_fallback_replay",
        "no_task_card_creation_for_ordinary_reply_replay",
        "state_card_selector_boundary_replay",
        "drift_latest_state_dedupe_root_repair_replay",
        "two_stage_locator_mapping_inventory_replay",
        "state_card_proven_unavailable_boundary_replay",
        "silent_routine_control_plane_validation_replay",
        "normal_path_no_persistent_visible_readback_card_replay",
        "timeout_is_not_state_card_eligibility_replay",
        "single_authoritative_continuation_path_replay",
        "external_continuation_state_forbidden_replay",
        "unnecessary_code_cleanup_impact_audit_replay",
        "public_contract_preservation_replay",
        "no_architectural_sprawl_replay",
        "no_internal_lease_or_duplicate_route_replay",
    }, maintainability
    adapter_conciseness = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-ADAPTER-CONCISENESS-001")
    assert adapter_conciseness["revision"] == 2, adapter_conciseness
    assert adapter_conciseness["effect"] == "keep_host_adapter_compact_complete_without_fixed_byte_cap_or_functional_loss", adapter_conciseness
    assert set(adapter_conciseness["acceptanceTests"]) >= {
        "adapter_conciseness_quality_replay",
        "adapter_functional_completeness_replay",
        "adapter_no_fixed_byte_cap_replay",
    }, adapter_conciseness
    bootstrap = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-BOOTSTRAP-SINGLE-SOURCE-001")
    assert bootstrap["revision"] == 1, bootstrap
    assert bootstrap["scope"] == "runtime", bootstrap
    assert bootstrap["effect"] == "keep_external_host_bootstrap_as_minimal_h7_route_only_and_resolve_all_behavioral_policy_from_versioned_core_rule_registry", bootstrap
    assert set(bootstrap["acceptanceTests"]) >= {
        "thin_bootstrap_no_behavioral_rule_duplication_replay",
        "bootstrap_registry_authority_replay",
        "adapter_freshness_refresh_replay",
    }, bootstrap
    shared_memory = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-UNIFIED-SHARED-MEMORY-001")
    assert shared_memory["revision"] == 2, shared_memory
    assert shared_memory["priority"] == 105, shared_memory
    assert shared_memory["scope"] == "runtime", shared_memory
    assert shared_memory["enforcement"] == "runtime", shared_memory
    assert shared_memory["entrypoint"] == "scripts/common.ps1", shared_memory
    assert shared_memory["effect"] == "enforce_one_canonical_shared_memory_root_with_workspace_task_session_provenance_reject_noncanonical_active_roots_retire_unscoped_session_binding_and_treat_legacy_agent_group_and_host_roots_as_read_only_migration_evidence", shared_memory
    assert set(shared_memory["acceptanceTests"]) >= {
        "shared_root_only_replay",
        "concurrent_scope_provenance_replay",
        "legacy_root_read_only_replay",
        "canonical_memory_root_entrypoints_replay",
        "legacy_marker_reactivation_denial_replay",
        "unscoped_session_binding_retirement_replay",
        "multi_agent_scope_isolation_replay",
        "private_memory_root_pointer_absence_replay",
    }, shared_memory
    absorption = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-ABILITY-ABSORPTION-001")
    assert absorption["priority"] == 105, absorption
    assert absorption["revision"] == 7, absorption
    assert absorption["effect"] == "absorb_verified_upstream_provenance_only_into_super_brain_native_procedures_with_functional_parity_or_enhancement_and_automatic_semantic_route_under_h7_core_rule_project_evidence_and_authorization_boundaries_require_a_current_hash_bound_offline_shadow_evaluation_and_retrieval_experiment_before_native_activation_withhold_unverified_capabilities_without_blocking_h7_or_project_knowledge_and_without_independent_install_direct_upstream_execution_or_user_named_skill_dependency", absorption
    assert absorption["enforcement"] == "runtime", absorption
    assert absorption["entrypoint"] == "runtime/execution_assist.py", absorption
    assert set(absorption["trigger"]) >= {
        "upstream_provenance",
        "native_capability",
        "capability_parity",
        "independent_skill_install",
        "direct_upstream_route",
    }, absorption
    assert set(absorption["acceptanceTests"]) >= {
        "capability_source_provenance_replay",
        "standalone_install_absence_replay",
        "capability_route_replay",
        "automatic_semantic_capability_route_replay",
        "capability_low_confidence_skip_replay",
        "capability_upstream_invocation_adapter_replay",
        "external_action_policy_replay",
        "absorbed_product_capability_proposal_gate_replay",
        "upstream_provenance_only_replay",
        "native_capability_parity_or_enhancement_replay",
        "capability_h7_core_rule_project_evidence_authorization_boundary_replay",
        "independent_install_and_direct_upstream_route_denial_replay",
        "execution_assist_native_route_replay",
        "capability_route_privacy_projection_replay",
        "capability_shadow_evaluation_current_binding_replay",
        "capability_shadow_missing_stale_tampered_withheld_replay",
        "capability_shadow_no_unsupported_activation_replay",
        "capability_shadow_retrieval_experiment_replay",
    }, absorption
    four_quadrant = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-FOUR-QUADRANT-EXECUTION-001")
    assert four_quadrant["revision"] == 1, four_quadrant
    assert four_quadrant["priority"] == 111, four_quadrant
    assert four_quadrant["scope"] == "runtime", four_quadrant
    assert four_quadrant["enforcement"] == "runtime", four_quadrant
    assert four_quadrant["entrypoint"] == "runtime/execution_assist.py", four_quadrant
    assert four_quadrant["effect"] == "enforce_four_quadrant_execution_with_confirmed_scope_material_question_budget_assumption_disclosure_risk_alternatives_tradeoffs_and_minimal_experiment_contract", four_quadrant
    assert set(four_quadrant["acceptanceTests"]) >= {
        "four_quadrant_material_question_budget_replay",
        "four_quadrant_assumption_disclosure_replay",
        "four_quadrant_risk_alternatives_tradeoffs_replay",
        "four_quadrant_minimal_experiment_replay",
        "execution_assist_privacy_replay",
    }, four_quadrant
    concurrent_state = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-CONCURRENT-STATE-CAS-001")
    assert concurrent_state["revision"] == 1, concurrent_state
    assert concurrent_state["priority"] == 112, concurrent_state
    assert concurrent_state["scope"] == "runtime", concurrent_state
    assert concurrent_state["enforcement"] == "runtime", concurrent_state
    assert concurrent_state["entrypoint"] == "runtime/brain_control.py", concurrent_state
    assert concurrent_state["effect"] == "enforce_scope_bound_compare_and_swap_idempotent_transition_and_conflict_withheld_reconcile_for_task_contract_hot_index_and_typed_memory_writes_without_raw_prompt_or_transcript_storage", concurrent_state
    assert set(concurrent_state["acceptanceTests"]) >= {
        "concurrent_task_contract_cas_replay",
        "idempotent_transition_replay",
        "hot_index_atomic_rebuild_replay",
        "cross_session_conflict_withheld_replay",
        "typed_memory_write_scope_cas_replay",
    }, concurrent_state
    task_retention = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-TEMPORARY-TASK-CARD-LIFECYCLE-001")
    assert task_retention["revision"] == 1, task_retention
    assert task_retention["priority"] == 113, task_retention
    assert task_retention["scope"] == "runtime", task_retention
    assert task_retention["enforcement"] == "runtime", task_retention
    assert task_retention["entrypoint"] == "runtime/brain_control.py", task_retention
    assert task_retention["effect"] == "treat_completed_task_cards_as_temporary_scope_bound_operational_state_keep_detailed_cards_visible_for_7_days_and_restorable_in_recycle_bin_for_the_following_15_days_hide_after_the_management_window_and_at_day_30_replace_the_task_card_projection_with_one_immutable_minimal_completion_evidence_record_without_raw_task_content_or_automatic_decision_promotion_never_age_clean_planned_active_paused_or_blocked_tasks_never_restore_compacted_cards_and_keep_physical_purge_separate_under_exact_target_set_user_authorization", task_retention
    assert set(task_retention["acceptanceTests"]) >= {
        "temporary_task_card_7_15_30_lifecycle_replay",
        "active_task_age_retention_exclusion_replay",
        "compact_completion_evidence_privacy_replay",
        "compacted_task_restore_denial_replay",
        "retention_window_cap_replay",
    }, task_retention
    defect_repair = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-DEFECT-ROOT-REPAIR-001")
    assert defect_repair["revision"] == 6, defect_repair
    assert defect_repair["scope"] == "runtime", defect_repair
    assert defect_repair["enforcement"] == "runtime", defect_repair
    assert defect_repair["entrypoint"] == "runtime/turn_runtime.py", defect_repair
    assert defect_repair["effect"] == "on_detected_drift_first_map_the_current_visible_tail_to_latest_scoped_task_state_and_live_project_evidence_prevent_duplicate_or_previously_failed_action_correct_the_current_display_and_scoped_state_then_repair_root_cause_and_require_same_path_regression_before_declaring_the_defect_resolved", defect_repair
    assert set(defect_repair["acceptanceTests"]) >= {
        "current_issue_correction_before_root_repair_replay",
        "root_cause_repair_replay",
        "affected_path_regression",
        "no_repeat_failed_route_replay",
        "preopen_visible_reply_correction_replay",
        "latest_task_state_before_drift_repair_replay",
        "drift_duplicate_action_prevention_replay",
        "drift_display_and_scoped_state_correction_replay",
        "drift_same_path_dynamic_replay",
    }, defect_repair
    latest_state = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-LATEST-STATE-001")
    assert latest_state["scope"] == "runtime", latest_state
    assert latest_state["revision"] == 30, latest_state
    assert latest_state["effect"] == "require_every_normal_same_workline_continuation_compaction_pause_resume_restart_and_model_switch_to_first_observe_the_time_latest_real_assistant_reply_currently_visible_in_the_current_thread_through_one_bounded_host_derived_observation_use_it_only_as_the_resume_locator_then_map_that_candidate_to_one_same_scope_task_workline_and_actual_project_phase_step_from_current_runtime_state_and_live_project_evidence_without_backscanning_old_summaries_contracts_or_anchors_for_a_replacement_never_allow_process_cache_lease_caller_capsule_or_prior_receipt_to_bypass_the_current_visible_locator_allow_ordinary_no_task_h7_continuity_without_creating_or_requiring_task_or_state_card_allow_state_card_selection_only_after_current_context_is_proven_unavailable_or_verified_parent_return_treat_timeout_slow_read_stale_index_or_missing_runtime_as_not_proven_unavailable_run_h7_and_proof_validation_silently_in_background_for_ordinary_continuation_and_block_only_formal_stage_or_high_impact_action_on_missing_validation_reject_user_message_memory_and_old_receipts_as_anchor_replacements_and_require_drift_repair_without_auto_contract_mutation", latest_state
    assert set(latest_state["acceptanceTests"]) >= {
        "latest_state_conflict_replay",
        "compression_recovery_replay",
        "resume_ack_event_replay",
        "continuous_turn_ack_suppression_replay",
        "h7_exact_recovery_presentation_replay",
        "h7_cli_process_restart_presentation_replay",
        "h7_parent_return_exact_open_replay",
        "nonstate_h7_turn_isolation_replay",
        "assistant_progress_checkpoint_recovery_replay",
        "latest_visible_progress_supersedes_stale_summary_replay",
        "handoff_summary_never_selects_recovery_anchor_replay",
        "exact_visible_recovery_receipt_replay",
        "visible_progress_receipt_required_replay",
        "latest_visible_progress_exact_anchor_replay",
        "visible_tail_assertion_required_replay",
        "visible_tail_assertion_mismatch_withheld_replay",
        "visible_tail_assertion_host_scope_replay",
        "automatic_host_tail_selection_replay",
        "legacy_tail_state_injection_denial_replay",
        "post_publication_checkpoint_observation_replay",
        "durable_visible_tail_auto_finalization_replay",
        "unclassified_visible_tail_auto_finalization_withheld_replay",
        "user_attested_visible_progress_reconcile_replay",
        "user_attested_anchor_requires_assistant_publication_replay",
        "close_user_attested_guard_replay",
        "checkpoint_scope_change_without_proof_atomic_withheld_replay",
        "preopen_assistant_progress_anchor_block_replay",
        "newer_preopen_assistant_message_blocks_walkback_replay",
        "auto_finalize_fallback_only_on_mismatch_replay",
        "terminal_summary_cannot_replace_durable_anchor_replay",
        "newer_assistant_message_blocks_old_durable_anchor_replay",
        "same_workline_visible_context_required_replay",
        "pause_resume_visible_context_replay",
        "parent_return_state_card_selection_replay",
        "visible_readback_cas_replay",
        "v4_durable_envelope_normal_anchor_replay",
        "v4_prefix_with_display_prose_replay",
        "v4_receipt_hash_exact_binding_replay",
        "bounded_current_thread_tail_read_replay",
        "no_history_scan_anchor_replay",
        "auto_alignment_detected_drift_only_replay",
        "drift_fallback_explicit_reconciliation_no_write_replay",
        "fresh_v4_publication_after_explicit_checkpoint_replay",
        "same_workline_current_thread_tail_required_replay",
        "current_visible_assistant_only_same_workline_replay",
        "plain_current_assistant_display_only_nonblocking_replay",
        "latest_durable_current_candidate_validation_replay",
        "drift_diagnosis_selector_isolation_replay",
        "boundary_plain_current_tail_exact_acknowledgement_replay",
        "strict_v4_durable_progress_and_stage_only_replay",
        "visible_tail_then_task_project_step_mapping_replay",
        "ordinary_no_task_no_card_replay",
        "state_card_context_unavailable_or_parent_return_only_replay",
        "background_h7_proof_nonblocking_ordinary_continuation_replay",
        "stage_or_high_impact_validation_gate_replay",
        "time_latest_visible_assistant_resume_locator_replay",
        "same_scope_task_workline_project_step_mapping_replay",
        "no_old_anchor_backscan_replay",
        "ordinary_no_task_h7_continuity_without_cards_replay",
        "state_card_proven_context_unavailable_replay",
        "silent_background_validation_replay",
        "drift_display_state_root_repair_same_path_replay",
        "normal_same_workline_transient_binding_no_persistent_card_replay",
        "compaction_pause_resume_restart_no_persistent_card_replay",
        "host_timeout_no_state_card_fallback_replay",
        "caller_supplied_capsule_forbidden_replay",
        "untrusted_visible_assertion_forbidden_replay",
        "no_internal_lease_visible_tail_bypass_replay",
    }, latest_state
    visible_progress = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-VISIBLE-PROGRESS-ANCHOR-001")
    assert visible_progress["revision"] == 27, visible_progress
    assert visible_progress["priority"] == 120, visible_progress
    assert visible_progress["scope"] == "runtime", visible_progress
    assert visible_progress["effect"] == "require_current_visible_context_time_latest_real_assistant_reply_as_resume_start_locator_before_one_same_scope_task_workline_and_live_project_phase_step_mapping_accept_only_one_bounded_host_derived_current_tail_observation_use_latest_durable_assistant_only_to_validate_that_same_candidate_is_h7_v4_for_durable_progress_or_formal_stage_transition_without_backward_selection_or_old_anchor_backscan_treat_plain_current_prose_as_non_authorizing_display_only_continuity_use_transient_h7_receipt_binding_without_persistent_visible_readback_or_state_card_on_normal_same_workline_compaction_pause_resume_or_restart_reject_process_cache_lease_caller_capsule_or_prior_receipt_as_locator_bypasses_allow_ordinary_no_task_h7_continuity_without_task_or_state_card_allow_state_card_only_after_current_context_is_proven_unavailable_or_verified_parent_return_reserve_latest_assistant_for_detected_drift_diagnosis_only_run_h7_and_proof_validation_silently_in_background_for_ordinary_continuation_and_require_current_validation_before_stage_or_high_impact_action", visible_progress
    assert set(visible_progress["trigger"]) >= {
        "resume", "continue", "compaction", "recovery", "status", "checkpoint", "phase_transition", "user_correction", "pause_resume", "parent_return",
    }, visible_progress
    assert set(visible_progress["acceptanceTests"]) >= {
        "visible_progress_receipt_required_replay",
        "latest_visible_progress_exact_anchor_replay",
        "visible_progress_project_proof_binding_replay",
        "visible_progress_scope_binding_replay",
        "stale_summary_cannot_resume_replay",
        "handoff_summary_never_selects_recovery_anchor_replay",
        "visible_tail_assertion_required_replay",
        "visible_tail_assertion_mismatch_withheld_replay",
        "visible_tail_assertion_host_scope_replay",
        "automatic_host_tail_selection_replay",
        "observed_tail_checkpoint_mismatch_without_write_replay",
        "durable_visible_tail_auto_finalization_replay",
        "unclassified_visible_tail_auto_finalization_withheld_replay",
        "h7_exact_recovery_presentation_replay",
        "h7_nonrecovery_ack_suppression_replay",
        "h7_parent_return_exact_open_replay",
        "user_attested_visible_progress_reconcile_replay",
        "cross_session_latest_visible_progress_recovery_replay",
        "user_attested_anchor_requires_assistant_publication_replay",
        "close_user_attested_guard_replay",
        "checkpoint_scope_change_without_proof_atomic_withheld_replay",
        "preopen_assistant_progress_anchor_block_replay",
        "newer_preopen_assistant_message_blocks_walkback_replay",
        "auto_finalize_fallback_only_on_mismatch_replay",
        "terminal_summary_cannot_replace_durable_anchor_replay",
        "newer_assistant_message_blocks_old_durable_anchor_replay",
        "visible_readback_cas_replay",
        "pause_resume_visible_context_replay",
        "parent_return_state_card_selection_replay",
        "v4_visible_anchor_shape_replay",
        "v4_visible_anchor_receipt_binding_replay",
        "v4_prefix_with_display_prose_replay",
        "bounded_current_thread_tail_retry_replay",
        "hot_update_identity_scope_proof_rebind_replay",
        "hot_update_hot_index_activation_rebuild_replay",
        "explicit_reconciliation_required_no_auto_mutation_replay",
        "host_three_line_compaction_replay",
        "host_truncation_fourth_line_withheld_replay",
        "host_five_second_timeout_replay",
        "host_timeout_no_fallback_replay",
        "current_visible_assistant_display_only_replay",
        "latest_durable_current_candidate_only_replay",
        "latest_assistant_drift_only_replay",
        "no_old_state_anchor_fallback_replay",
        "plain_boundary_tail_acknowledgement_without_progress_promotion_replay",
        "v4_current_candidate_required_for_formal_stage_transition_replay",
        "visible_tail_before_task_step_mapping_replay",
        "no_task_card_for_ordinary_reply_replay",
        "state_card_context_unavailable_only_replay",
        "background_validation_nonblocking_ordinary_replay",
        "high_impact_current_validation_required_replay",
        "time_latest_visible_reply_locator_replay",
        "tail_locator_then_same_scope_mapping_replay",
        "no_old_anchor_backscan_for_locator_replay",
        "ordinary_no_task_h7_without_cards_replay",
        "state_card_only_after_proven_context_unavailable_replay",
        "silent_background_continuity_validation_replay",
        "normal_same_workline_transient_h7_binding_replay",
        "no_persistent_visible_readback_card_replay",
        "timeout_not_context_unavailable_no_card_replay",
        "caller_supplied_capsule_forbidden_replay",
        "untrusted_visible_assertion_forbidden_replay",
        "current_visible_locator_required_every_same_workline_turn_replay",
    }, visible_progress
    progress_truth = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-PROGRESS-TRUTH-001")
    assert progress_truth["revision"] == 14, progress_truth
    assert progress_truth["priority"] == 115, progress_truth
    assert progress_truth["scope"] == "runtime", progress_truth
    assert progress_truth["effect"] == "map_normal_continuation_from_current_visible_tail_resume_locator_to_one_same_scope_task_workline_and_actual_project_phase_step_use_transient_h7_receipt_binding_without_persistent_visible_readback_or_state_card_for_normal_same_workline_compaction_pause_resume_or_restart_run_h7_checkpoint_and_live_project_proof_validation_silently_in_background_without_blocking_ordinary_continuation_allow_plain_current_tail_only_as_display_not_progress_truth_require_current_h7_checkpoint_live_project_proof_and_host_readback_user_stage_receipt_before_published_progress_phase_completion_formal_stage_or_high_impact_action_and_after_detected_drift_require_actual_task_project_deduplication_current_state_correction_root_repair_and_same_path_regression", progress_truth
    assert progress_truth["enforcement"] == "runtime", progress_truth
    assert progress_truth["entrypoint"] == "runtime/turn_runtime.py", progress_truth
    assert set(progress_truth["trigger"]) >= {
        "design",
        "plan",
        "continue",
        "recovery",
        "status",
        "stage_complete",
        "phase_transition",
        "verification",
    }, progress_truth
    assert set(progress_truth["acceptanceTests"]) >= {
        "h7_progress_truth_projection_replay",
        "project_progress_without_evidence_withheld_replay",
        "phase_evidence_verification_binding_replay",
        "recovery_progress_truth_replay",
        "visible_progress_project_proof_binding_replay",
        "observed_tail_checkpoint_mismatch_without_write_replay",
        "durable_visible_tail_auto_finalization_replay",
        "unclassified_visible_tail_auto_finalization_withheld_replay",
        "checkpoint_scope_change_without_proof_atomic_withheld_replay",
        "terminal_summary_cannot_replace_durable_anchor_replay",
        "v4_prefix_with_display_prose_replay",
        "truncated_text_without_v4_prefix_replay",
        "h7_checkpoint_live_proof_phase_claim_replay",
        "host_readback_stage_receipt_replay",
        "forward_stage_transition_provenance_replay",
        "explicit_checkpoint_required_after_drift_replay",
        "visible_readback_cas_replay",
        "plain_current_tail_display_acknowledgement_replay",
        "v4_only_progress_truth_and_formal_stage_transition_replay",
        "background_proof_validation_nonblocking_normal_continuation_replay",
        "current_validation_required_for_high_impact_action_replay",
        "drift_latest_task_state_dedupe_root_repair_replay",
        "tail_locator_same_scope_project_step_truth_replay",
        "silent_background_progress_validation_replay",
        "drift_current_state_correction_then_root_repair_replay",
        "normal_continuation_transient_receipt_no_state_card_replay",
    }, progress_truth
    delivery = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-EFFICIENT-DELIVERY-001")
    assert delivery["priority"] == 95, delivery
    assert delivery["revision"] == 5, delivery
    assert delivery["enforcement"] == "runtime", delivery
    assert delivery["entrypoint"] == "runtime/turn_runtime.py", delivery
    assert delivery["effect"] == "solve_actual_project_work_fast_and_correctly_with_minimal_verified_control_plane_overhead_measure_only_bounded_actual_h7_runtime_latency_and_report_explicit_budget_state_use_one_bounded_current_thread_tail_observation_without_project_tree_scan_on_normal_continuation_use_fastest_deterministic_feedback_first_parallelize_only_independent_bounded_checks_correct_current_state_then_repair_root_cause_then_replay_prefer_concrete_fix_and_verification_over_repeated_explanation_or_status_chatter_avoid_extra_runtime_processes_or_duplicate_routes_and_never_claim_unverified_progress", delivery
    assert set(delivery["acceptanceTests"]) >= {
        "bounded_parallel_delivery_replay",
        "fast_feedback_timeout_replay",
        "child_close_after_return_replay",
        "current_thread_tail_latency_replay",
        "concrete_fix_over_status_chatter_replay",
        "unverified_progress_claim_denial_replay",
        "fast_path_preserves_verification_replay",
        "bounded_visible_tail_fast_path_replay",
        "no_extra_mcp_process_on_hot_path_replay",
        "run_observability_measured_only_replay",
        "run_observability_budget_and_privacy_replay",
        "run_observability_telemetry_evidence_consistency_replay",
    }, delivery
    runtime_independence = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-RUNTIME-ADAPTER-INDEPENDENCE-001")
    assert runtime_independence["revision"] == 2, runtime_independence
    assert runtime_independence["priority"] == 110, runtime_independence
    assert runtime_independence["scope"] == "runtime", runtime_independence
    assert runtime_independence["effect"] == "keep_core_runtime_and_memory_independent_of_all_optional_host_adapters_and_make_host_specific_startup_failures_non_authorizing", runtime_independence
    assert set(runtime_independence["acceptanceTests"]) >= {
        "adapter_absence_core_health_replay",
        "adapter_rehydrate_non_destructive_replay",
        "zcode_optional_host_core_ready_replay",
        "generic_agent_discovery_without_zcode_replay",
        "host_adapter_failure_not_core_failure_replay",
    }, runtime_independence
    primary_entry = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-PRIMARY-HOST-ENTRY-001")
    assert primary_entry["revision"] == 2, primary_entry
    assert primary_entry["priority"] == 117, primary_entry
    assert primary_entry["scope"] == "runtime", primary_entry
    assert primary_entry["effect"] == "require_the_current_primary_codex_host_entry_and_live_mcp_served_runtime_identity_and_rule_registry_for_host_ready_state_keep_zcode_and_other_compatibility_hosts_explicit_opt_in_and_withhold_stale_or_missing_primary_entry_or_long_lived_runtime_drift_without_reporting_optional_or_degraded_readiness", primary_entry
    assert primary_entry["entrypoint"] == "runtime/brain_core.py", primary_entry
    assert set(primary_entry["acceptanceTests"]) >= {
        "primary_codex_entry_freshness_replay",
        "mcp_runtime_identity_binding_replay",
        "stale_mcp_identity_withheld_replay",
        "live_mcp_runtime_registry_drift_withheld_replay",
        "zcode_opt_in_install_replay",
        "primary_entry_no_optional_health_replay",
    }, primary_entry
    proposal_gate = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-PROPOSAL-GATE-001")
    assert proposal_gate["revision"] == 4, proposal_gate
    assert "mutation_guard" in proposal_gate["trigger"], proposal_gate
    assert proposal_gate["effect"] == "require_exact_user_or_approved_plan_authorization_for_destructive_mutation", proposal_gate
    assert proposal_gate["entrypoint"] == "scripts/cognitive-enforce.ps1", proposal_gate
    assert set(proposal_gate["acceptanceTests"]) >= {
        "proposal_approval_gate_replay",
        "exact_action_target_impact_authorization_replay",
        "vague_instruction_denial_replay",
        "wildcard_target_drift_fail_closed_replay",
    }, proposal_gate
    auto_resume = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-AUTO-RESUME-001")
    assert auto_resume["revision"] == 6, auto_resume
    assert auto_resume["enforcement"] == "runtime", auto_resume
    assert auto_resume["entrypoint"] == "runtime/continuation_policy.py", auto_resume
    assert auto_resume["effect"] == "resume_latest_approved_parent_after_insertion_only_when_a_concrete_authorized_parent_action_remains_and_treat_a_verified_zero_pending_canonical_plan_in_complete_phase_without_parent_as_terminal_not_continue_keep_one_unique_non_wake_eligible_structurally_verified_terminal_contract_available_only_for_the_h7_finalization_checkpoint_that_rebinds_that_exact_terminal_candidate_and_may_refresh_a_withheld_project_proof_only_when_that_same_checkpoint_supplies_fresh_hash_verified_live_project_proof_never_for_normal_auto_wake_or_ordinary_continuation", auto_resume
    assert set(auto_resume["trigger"]) >= {"continue", "task_complete", "final_closeout"}, auto_resume
    assert set(auto_resume["acceptanceTests"]) >= {
        "parent_resume_replay",
        "cross_session_resume_replay",
        "verified_completed_plan_terminal_replay",
        "incomplete_plan_not_terminal_replay",
        "terminal_finalization_no_auto_wake_replay",
        "terminal_finalization_unique_scope_replay",
        "terminal_finalization_proof_refresh_replay",
        "terminal_finalization_contract_binding_replay",
    }, auto_resume
    child_lifecycle = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-CHILD-LIFECYCLE-001")
    assert child_lifecycle["revision"] == 3, child_lifecycle
    assert child_lifecycle["effect"] == "close_only_verified_agent_child_and_never_mutate_parent_or_user_task", child_lifecycle
    assert set(child_lifecycle["acceptanceTests"]) >= {
        "mcp_transport_cleanup_exclusion_replay",
        "parent_user_task_mutation_denial_replay",
        "unknown_child_identity_fail_closed_replay",
    }, child_lifecycle
    stage_verify = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-STAGE-VERIFY-001")
    assert stage_verify["revision"] == 4, stage_verify
    assert stage_verify["entrypoint"] == "scripts/execution-contract.ps1", stage_verify
    assert stage_verify["effect"] == "require_current_h7_phase_closeout_live_project_proof_and_host_readback_user_stage_receipt_before_forward_formal_stage_transition", stage_verify
    assert set(stage_verify["acceptanceTests"]) >= {
        "stage_gate_replay",
        "verify_each_stage_before_next_stage",
        "host_stage_receipt_replay",
        "forward_stage_live_proof_replay",
        "plain_stage_closeout_required_replay",
    }, stage_verify
    stage_receipt = next(rule for rule in current["rules"] if rule["ruleId"] == "SB-STAGE-USER-RECEIPT-001")
    assert stage_receipt["revision"] == 2, stage_receipt
    assert stage_receipt["priority"] == 95, stage_receipt
    assert stage_receipt["effect"] == "require_h7_bound_host_readback_user_visible_stage_receipt_before_next_phase", stage_receipt
    assert set(stage_receipt["acceptanceTests"]) >= {
        "stage_user_receipt_replay",
        "stage_receipt_before_advance_replay",
        "host_readback_stage_receipt_replay",
        "stage_receipt_h7_proof_binding_replay",
    }, stage_receipt

    design = public_projection(current, signals=("design",))
    assert design["applicableRuleIds"] == [
        "SB-PROJECT-GROUNDED-DESIGN-001",
        "SB-FOUR-QUADRANT-EXECUTION-001",
        "SB-PROGRESS-TRUTH-001",
        "SB-ON-DEMAND-PROJECT-KNOWLEDGE-001",
    ], design
    continuation = public_projection(current, signals=("continue",))
    assert continuation["applicableRuleIds"] == [
        "SB-LATEST-STATE-001",
        "SB-VISIBLE-PROGRESS-ANCHOR-001",
        "SB-PROGRESS-TRUTH-001",
        "SB-AUTO-RESUME-001",
        "SB-H7-ACTIVATION-001",
    ], continuation
    mutation = public_projection(current, signals=("mutation_guard",))
    assert mutation["applicableRuleIds"] == ["SB-PROPOSAL-GATE-001"], mutation
    adapter_loss = public_projection(current, signals=("skill_deleted",))
    assert adapter_loss["applicableRuleIds"] == ["SB-RUNTIME-ADAPTER-INDEPENDENCE-001"], adapter_loss
    primary_entry_projection = public_projection(current, signals=("primary_host_entry",))
    assert primary_entry_projection["applicableRuleIds"] == ["SB-PRIMARY-HOST-ENTRY-001"], primary_entry_projection
    delivery_projection = public_projection(current, signals=("optimization",))
    assert "SB-EFFICIENT-DELIVERY-001" in delivery_projection["applicableRuleIds"], delivery_projection
    four_quadrant_projection = public_projection(current, signals=("design",))
    assert "SB-FOUR-QUADRANT-EXECUTION-001" in four_quadrant_projection["applicableRuleIds"], four_quadrant_projection
    concurrency_projection = public_projection(current, signals=("concurrency",))
    assert concurrency_projection["applicableRuleIds"] == ["SB-CONCURRENT-STATE-CAS-001"], concurrency_projection
    stage_projection = public_projection(current, signals=("stage_complete",))
    assert stage_projection["applicableRuleIds"] == [
        "SB-PROGRESS-TRUTH-001",
        "SB-STAGE-VERIFY-001",
        "SB-H7-ACTIVATION-001",
        "SB-STAGE-USER-RECEIPT-001",
    ], stage_projection
    status_projection = public_projection(current, signals=("status",))
    assert status_projection["applicableRuleIds"] == [
        "SB-LATEST-STATE-001",
        "SB-VISIBLE-PROGRESS-ANCHOR-001",
        "SB-PROGRESS-TRUTH-001",
        "SB-H7-ACTIVATION-001",
        "SB-INDEPENDENT-CONTROL-PLANE-AGENT-001",
    ], status_projection
    control_plane_projection = public_projection(current, signals=("control_plane_agent",))
    assert control_plane_projection["applicableRuleIds"] == ["SB-INDEPENDENT-CONTROL-PLANE-AGENT-001"], control_plane_projection
    correction_projection = public_projection(current, signals=("user_correction",))
    assert correction_projection["applicableRuleIds"] == [
        "SB-RULE-MEMORY-SPLIT-001",
        "SB-LATEST-STATE-001",
        "SB-VISIBLE-PROGRESS-ANCHOR-001",
    ], correction_projection
    maintenance_projection = public_projection(current, signals=("maintenance",))
    assert "SB-H7-ACTIVATION-001" in maintenance_projection["applicableRuleIds"], maintenance_projection
    learning_projection = public_projection(current, signals=("learning",))
    assert "SB-H7-ACTIVATION-001" in learning_projection["applicableRuleIds"], learning_projection
    legacy_transport_projection = public_projection(current, signals=("p7", "hook"))
    assert legacy_transport_projection["applicableRuleIds"] == ["SB-H7-ACTIVATION-001"], legacy_transport_projection
    greeting = public_projection(current, signals=("greeting",))
    assert greeting["applicableRuleIds"] == [], greeting
    assert greeting["applicableEffectsHash"] == "", greeting
    assert greeting["signalStored"] is False, greeting

    with tempfile.TemporaryDirectory(prefix="super-brain-rule-registry-") as raw:
        fixture = Path(raw) / "package"
        write_fixture(fixture, source, manifest)

        hash_mismatch = clone(source)
        assert isinstance(hash_mismatch, dict)
        assert isinstance(hash_mismatch["rules"], list)
        hash_mismatch["rules"][0]["effect"] = "project_root_evidence_gate_changed"
        write_fixture(fixture, hash_mismatch, manifest)
        broken = load_registry(fixture, manifest=manifest)
        assert broken["code"] == "CORE_RULE_REGISTRY_HASH_MISMATCH", broken

        missing_required = clone(source)
        assert isinstance(missing_required, dict)
        missing_required["rules"] = [
            rule for rule in missing_required["rules"]
            if rule["ruleId"] != "SB-H7-ACTIVATION-001"
        ]
        write_fixture(fixture, sign(missing_required), manifest)
        missing_required_result = load_registry(fixture, manifest=manifest)
        assert missing_required_result["code"] == "CORE_RULE_REGISTRY_REQUIRED_RULE_MISSING", missing_required_result

        duplicate = clone(source)
        assert isinstance(duplicate, dict)
        duplicate["rules"][1]["ruleId"] = duplicate["rules"][0]["ruleId"]
        write_fixture(fixture, sign(duplicate), manifest)
        duplicate_result = load_registry(fixture, manifest=manifest)
        assert duplicate_result["code"] == "CORE_RULE_REGISTRY_RULE_ID_INVALID", duplicate_result

        wrong_manifest = clone(manifest)
        assert isinstance(wrong_manifest, dict)
        wrong_manifest["coreRuleRegistry"]["path"] = "wrong-rules.json"
        write_fixture(fixture, source, wrong_manifest)
        manifest_result = load_registry(fixture, manifest=wrong_manifest)
        assert manifest_result["code"] == "CORE_RULE_REGISTRY_MANIFEST_PATH_MISMATCH", manifest_result

        write_fixture(fixture, b"\xef\xbb\xbf" + json.dumps(source).encode("utf-8"), manifest)
        bom = load_registry(fixture)
        assert bom["code"] == "CORE_RULE_REGISTRY_BOM_FORBIDDEN", bom

        write_fixture(fixture, b"\xff\xfe\x00", manifest)
        utf8 = load_registry(fixture)
        assert utf8["code"] == "CORE_RULE_REGISTRY_UTF8_INVALID", utf8

        write_fixture(fixture, b"{invalid", manifest)
        invalid_json = load_registry(fixture)
        assert invalid_json["code"] == "CORE_RULE_REGISTRY_JSON_INVALID", invalid_json

        (fixture / "super-brain-rules.json").unlink()
        missing = load_registry(fixture, manifest=manifest)
        assert missing["code"] == "CORE_RULE_REGISTRY_MISSING", missing

    print("CORE_RULE_REGISTRY_REGRESSION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
