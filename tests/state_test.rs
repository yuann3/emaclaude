use emaclaude::state::*;

fn default_config() -> WorkflowConfig {
    WorkflowConfig::default()
}

#[test]
fn idle_to_coding_on_planning_done() {
    let config = default_config();
    let t = WorkflowState::Idle.next(
        Event::PlanningDone {
            prompt: "implement feature X".into(),
            spec_path: "specs/feature-x.md".into(),
        },
        &config,
    );
    assert_eq!(t.state, WorkflowState::Coding);
    assert_eq!(t.effects.len(), 2);
    assert_eq!(
        t.effects[0],
        SideEffect::SpawnCodingAgent {
            prompt: "implement feature X".into(),
            spec_path: "specs/feature-x.md".into(),
        }
    );
    assert_eq!(t.effects[1], SideEffect::SpawnReviewAgent);
}

#[test]
fn coding_to_reviewing_on_coding_done() {
    let config = default_config();
    let t = WorkflowState::Coding.next(
        Event::CodingDone {
            branch: "feature-x".into(),
        },
        &config,
    );
    assert_eq!(t.state, WorkflowState::Reviewing);
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToReviewAgent { prompt } => {
            assert!(prompt.contains("feature-x"));
            assert!(prompt.contains("emaclaude-signal review-done"));
            assert!(!prompt.contains("curl"));
            assert!(!prompt.contains("localhost"));
        }
        other => panic!("Expected SendToReviewAgent, got {:?}", other),
    }
}

#[test]
fn reviewing_to_coding_on_changes_needed() {
    let config = default_config();
    let t = WorkflowState::Reviewing.next(
        Event::ReviewDone {
            status: ReviewStatus::ChangesNeeded,
            feedback: "fix the error handling".into(),
        },
        &config,
    );
    assert_eq!(t.state, WorkflowState::Coding);
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToCodingAgent { prompt } => {
            assert!(prompt.contains("fix the error handling"));
            assert!(prompt.contains("emaclaude-signal coding-done"));
            assert!(!prompt.contains("curl"));
            assert!(!prompt.contains("localhost"));
        }
        other => panic!("Expected SendToCodingAgent, got {:?}", other),
    }
}

#[test]
fn reviewing_to_confirming_on_approved() {
    let config = default_config();
    let t = WorkflowState::Reviewing.next(
        Event::ReviewDone {
            status: ReviewStatus::Approved,
            feedback: "looks good".into(),
        },
        &config,
    );
    assert_eq!(t.state, WorkflowState::Confirming { approval_count: 1 });
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToReviewAgent { prompt } => {
            assert!(prompt.contains("Re-review"));
            assert!(prompt.contains("emaclaude-signal review-done"));
            assert!(!prompt.contains("curl"));
            assert!(!prompt.contains("localhost"));
        }
        other => panic!("Expected SendToReviewAgent, got {:?}", other),
    }
}

#[test]
fn confirming_increments_on_approved() {
    let config = default_config(); // confirmation_loops = 2
    let t = WorkflowState::Confirming { approval_count: 1 }.next(
        Event::ReviewDone {
            status: ReviewStatus::Approved,
            feedback: "still good".into(),
        },
        &config,
    );
    // 1 < 2, so stays in Confirming with count incremented
    assert_eq!(t.state, WorkflowState::Confirming { approval_count: 2 });
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToReviewAgent { prompt } => {
            assert!(prompt.contains("Re-review"));
            assert!(prompt.contains("emaclaude-signal review-done"));
            assert!(!prompt.contains("curl"));
            assert!(!prompt.contains("localhost"));
        }
        other => panic!("Expected SendToReviewAgent, got {:?}", other),
    }
}

#[test]
fn confirming_to_human_review() {
    let config = default_config(); // confirmation_loops = 2
    let t = WorkflowState::Confirming { approval_count: 2 }.next(
        Event::ReviewDone {
            status: ReviewStatus::Approved,
            feedback: "confirmed good".into(),
        },
        &config,
    );
    // 2 >= 2, transitions to HumanReview
    assert_eq!(t.state, WorkflowState::HumanReview);
    assert_eq!(t.effects.len(), 2);
    assert_eq!(t.effects[0], SideEffect::OpenDiffView);
    match &t.effects[1] {
        SideEffect::Notify { message } => {
            assert!(message.contains("human review"));
        }
        other => panic!("Expected Notify, got {:?}", other),
    }
}

#[test]
fn confirming_resets_on_changes_needed() {
    let config = default_config();
    let t = WorkflowState::Confirming { approval_count: 2 }.next(
        Event::ReviewDone {
            status: ReviewStatus::ChangesNeeded,
            feedback: "actually found a bug".into(),
        },
        &config,
    );
    assert_eq!(t.state, WorkflowState::Coding);
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToCodingAgent { prompt } => {
            assert!(prompt.contains("actually found a bug"));
            assert!(prompt.contains("emaclaude-signal coding-done"));
            assert!(!prompt.contains("curl"));
            assert!(!prompt.contains("localhost"));
        }
        other => panic!("Expected SendToCodingAgent, got {:?}", other),
    }
}

#[test]
fn human_review_sends_comments_to_coding_agent() {
    let config = default_config();
    let comments = vec![
        Comment {
            file: "src/main.rs".into(),
            line: 42,
            end_line: Some(45),
            text: "rename this variable".into(),
        },
        Comment {
            file: "src/lib.rs".into(),
            line: 10,
            end_line: None,
            text: "add docs".into(),
        },
    ];
    let t = WorkflowState::HumanReview.next(Event::HumanComments { comments }, &config);
    assert_eq!(t.state, WorkflowState::HumanReview);
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToCodingAgent { prompt } => {
            assert!(prompt.contains("src/main.rs:42-45: rename this variable"));
            assert!(prompt.contains("src/lib.rs:10: add docs"));
            assert!(prompt.contains("emaclaude-signal coding-done"));
            assert!(!prompt.contains("curl"));
            assert!(!prompt.contains("localhost"));
        }
        other => panic!("Expected SendToCodingAgent, got {:?}", other),
    }
}

#[test]
fn human_review_to_pr_created() {
    let config = default_config();
    let t = WorkflowState::HumanReview.next(Event::CreatePr, &config);
    assert_eq!(t.state, WorkflowState::PrCreated);
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToCodingAgent { prompt } => {
            assert!(prompt.contains("pull request"));
            assert!(prompt.contains("emaclaude-signal coding-done"));
            assert!(!prompt.contains("curl"));
            assert!(!prompt.contains("localhost"));
        }
        other => panic!("Expected SendToCodingAgent, got {:?}", other),
    }
}

#[test]
fn pr_created_addresses_github_reviews() {
    let config = default_config();
    let t = WorkflowState::PrCreated.next(Event::AddressGithubReviews { pr_number: 42 }, &config);
    assert_eq!(t.state, WorkflowState::PrCreated);
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToCodingAgent { prompt } => {
            assert!(prompt.contains("42"));
            assert!(prompt.contains("gh api"));
            assert!(prompt.contains("emaclaude-signal coding-done"));
            assert!(!prompt.contains("curl"));
            assert!(!prompt.contains("localhost"));
        }
        other => panic!("Expected SendToCodingAgent, got {:?}", other),
    }
}

#[test]
fn clear_session_from_any_state() {
    let config = default_config();
    let states = vec![
        WorkflowState::Idle,
        WorkflowState::Coding,
        WorkflowState::Reviewing,
        WorkflowState::Confirming { approval_count: 1 },
        WorkflowState::HumanReview,
        WorkflowState::PrCreated,
    ];
    for state in states {
        let t = state.clone().next(Event::ClearSession, &config);
        assert_eq!(
            t.state,
            WorkflowState::Idle,
            "ClearSession from {:?}",
            state
        );
        assert_eq!(t.effects.len(), 2);
        match &t.effects[0] {
            SideEffect::Notify { message } => {
                assert!(message.contains("cleared"));
            }
            other => panic!("Expected Notify, got {:?}", other),
        }
        assert_eq!(t.effects[1], SideEffect::Shutdown);
    }
}

#[test]
fn human_review_coding_done_refreshes_diff() {
    let config = default_config();
    let t = WorkflowState::HumanReview.next(
        Event::CodingDone {
            branch: "feat/x".into(),
        },
        &config,
    );
    assert_eq!(t.state, WorkflowState::HumanReview);
    assert!(t.effects.contains(&SideEffect::RefreshDiffView));
}

#[test]
fn pr_created_coding_done_refreshes_diff() {
    let config = default_config();
    let t = WorkflowState::PrCreated.next(
        Event::CodingDone {
            branch: "feat/x".into(),
        },
        &config,
    );
    assert_eq!(t.state, WorkflowState::PrCreated);
    assert!(t.effects.contains(&SideEffect::RefreshDiffView));
}

#[test]
fn unhandled_transition_returns_same_state() {
    let config = default_config();
    // Idle + CodingDone should be unhandled
    let t = WorkflowState::Idle.next(Event::CodingDone { branch: "x".into() }, &config);
    assert_eq!(t.state, WorkflowState::Idle);
    assert!(t.effects.is_empty());
}

// --- New tests for JSON contract ---

#[test]
fn json_round_trip_transition_input() {
    let input_json = r#"{
        "state": "Idle",
        "event": {
            "PlanningDone": {
                "prompt": "implement feature X",
                "spec_path": "specs/feature-x.md"
            }
        },
        "config": {
            "confirmation_loops": 2
        }
    }"#;

    #[derive(serde::Deserialize)]
    struct TransitionInput {
        state: WorkflowState,
        event: Event,
        config: WorkflowConfig,
    }

    let parsed: TransitionInput = serde_json::from_str(input_json).unwrap();
    assert_eq!(parsed.state, WorkflowState::Idle);
    assert_eq!(parsed.config.confirmation_loops, 2);

    let t = parsed.state.next(parsed.event, &parsed.config);
    assert_eq!(t.state, WorkflowState::Coding);

    // Serialize the output
    let output_json = serde_json::to_value(&t).unwrap();
    assert_eq!(output_json["state"], "Coding");
    assert!(output_json["effects"].is_array());
    assert_eq!(output_json["effects"].as_array().unwrap().len(), 2);
}

#[test]
fn json_round_trip_confirming_state() {
    let state = WorkflowState::Confirming { approval_count: 3 };
    let json = serde_json::to_value(&state).unwrap();
    assert_eq!(
        json,
        serde_json::json!({"Confirming": {"approval_count": 3}})
    );
    let deserialized: WorkflowState = serde_json::from_value(json).unwrap();
    assert_eq!(deserialized, state);
}

#[test]
fn json_round_trip_simple_states() {
    for (state, expected_json) in [
        (WorkflowState::Idle, "\"Idle\""),
        (WorkflowState::Coding, "\"Coding\""),
        (WorkflowState::Reviewing, "\"Reviewing\""),
        (WorkflowState::HumanReview, "\"HumanReview\""),
        (WorkflowState::PrCreated, "\"PrCreated\""),
    ] {
        let json = serde_json::to_string(&state).unwrap();
        assert_eq!(json, expected_json);
        let deserialized: WorkflowState = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized, state);
    }
}

#[test]
fn json_side_effect_with_data() {
    let effect = SideEffect::SpawnCodingAgent {
        prompt: "do stuff".into(),
        spec_path: "spec.md".into(),
    };
    let json = serde_json::to_value(&effect).unwrap();
    assert_eq!(
        json,
        serde_json::json!({"SpawnCodingAgent": {"prompt": "do stuff", "spec_path": "spec.md"}})
    );
}

#[test]
fn json_side_effect_without_data() {
    let effect = SideEffect::SpawnReviewAgent;
    let json = serde_json::to_string(&effect).unwrap();
    assert_eq!(json, "\"SpawnReviewAgent\"");
}

#[test]
fn json_event_clear_session() {
    let event: Event = serde_json::from_str("\"ClearSession\"").unwrap();
    assert_eq!(event, Event::ClearSession);
}

#[test]
fn json_event_with_data() {
    let json = r#"{"ReviewDone": {"status": "Approved", "feedback": "lgtm"}}"#;
    let event: Event = serde_json::from_str(json).unwrap();
    assert_eq!(
        event,
        Event::ReviewDone {
            status: ReviewStatus::Approved,
            feedback: "lgtm".into(),
        }
    );
}

#[test]
fn json_comment_with_optional_end_line() {
    let comment = Comment {
        file: "src/main.rs".into(),
        line: 12,
        end_line: Some(14),
        text: "tighten this branch".into(),
    };
    let json = serde_json::to_value(&comment).unwrap();
    assert_eq!(json["file"], "src/main.rs");
    assert_eq!(json["line"], 12);
    assert_eq!(json["end_line"], 14);
    assert_eq!(json["text"], "tighten this branch");

    let decoded: Comment = serde_json::from_value(json).unwrap();
    assert_eq!(decoded, comment);
}

#[test]
fn cycle_complete_from_coding() {
    let config = default_config();
    let t = WorkflowState::Coding.next(Event::CycleComplete, &config);
    assert_eq!(t.state, WorkflowState::Idle);
    assert!(
        t.effects
            .iter()
            .any(|e| matches!(e, SideEffect::ResetCodingAndReview))
    );
    assert!(
        t.effects
            .iter()
            .any(|e| matches!(e, SideEffect::InsertIntoPlanningBuffer { .. }))
    );
}

#[test]
fn cycle_complete_from_reviewing() {
    let config = default_config();
    let t = WorkflowState::Reviewing.next(Event::CycleComplete, &config);
    assert_eq!(t.state, WorkflowState::Idle);
    assert!(
        t.effects
            .iter()
            .any(|e| matches!(e, SideEffect::ResetCodingAndReview))
    );
}

#[test]
fn cycle_complete_from_confirming() {
    let config = default_config();
    let t = WorkflowState::Confirming { approval_count: 1 }.next(Event::CycleComplete, &config);
    assert_eq!(t.state, WorkflowState::Idle);
    assert!(
        t.effects
            .iter()
            .any(|e| matches!(e, SideEffect::ResetCodingAndReview))
    );
}

#[test]
fn cycle_complete_from_human_review() {
    let config = default_config();
    let t = WorkflowState::HumanReview.next(Event::CycleComplete, &config);
    assert_eq!(t.state, WorkflowState::Idle);
    assert!(
        t.effects
            .iter()
            .any(|e| matches!(e, SideEffect::ResetCodingAndReview))
    );
}

#[test]
fn cycle_complete_from_pr_created() {
    let config = default_config();
    let t = WorkflowState::PrCreated.next(Event::CycleComplete, &config);
    assert_eq!(t.state, WorkflowState::Idle);
    assert!(
        t.effects
            .iter()
            .any(|e| matches!(e, SideEffect::ResetCodingAndReview))
    );
}

#[test]
fn cycle_complete_from_idle_is_noop() {
    let config = default_config();
    let t = WorkflowState::Idle.next(Event::CycleComplete, &config);
    assert_eq!(t.state, WorkflowState::Idle);
    assert!(t.effects.is_empty());
}

#[test]
fn cycle_complete_insert_message_content() {
    let config = default_config();
    let t = WorkflowState::HumanReview.next(Event::CycleComplete, &config);
    let msg = t.effects.iter().find_map(|e| match e {
        SideEffect::InsertIntoPlanningBuffer { message } => Some(message.as_str()),
        _ => None,
    });
    assert!(msg.is_some());
    assert!(msg.unwrap().contains("Implementation is done"));
}

#[test]
fn json_event_cycle_complete() {
    let event: Event = serde_json::from_str("\"CycleComplete\"").unwrap();
    assert_eq!(event, Event::CycleComplete);
}

#[test]
fn json_side_effect_reset_coding_and_review() {
    let effect = SideEffect::ResetCodingAndReview;
    let json = serde_json::to_string(&effect).unwrap();
    assert_eq!(json, "\"ResetCodingAndReview\"");
}

#[test]
fn json_side_effect_insert_into_planning_buffer() {
    let effect = SideEffect::InsertIntoPlanningBuffer {
        message: "hello".into(),
    };
    let json = serde_json::to_value(&effect).unwrap();
    assert_eq!(
        json,
        serde_json::json!({"InsertIntoPlanningBuffer": {"message": "hello"}})
    );
}

#[test]
fn no_curl_or_localhost_in_any_prompt() {
    let config = default_config();
    // Collect all transitions that produce prompt text
    let transitions = vec![
        WorkflowState::Coding.next(Event::CodingDone { branch: "b".into() }, &config),
        WorkflowState::Reviewing.next(
            Event::ReviewDone {
                status: ReviewStatus::ChangesNeeded,
                feedback: "f".into(),
            },
            &config,
        ),
        WorkflowState::Reviewing.next(
            Event::ReviewDone {
                status: ReviewStatus::Approved,
                feedback: "".into(),
            },
            &config,
        ),
        WorkflowState::Confirming { approval_count: 1 }.next(
            Event::ReviewDone {
                status: ReviewStatus::Approved,
                feedback: "".into(),
            },
            &config,
        ),
        WorkflowState::Confirming { approval_count: 1 }.next(
            Event::ReviewDone {
                status: ReviewStatus::ChangesNeeded,
                feedback: "f".into(),
            },
            &config,
        ),
        WorkflowState::HumanReview.next(
            Event::HumanComments {
                comments: vec![Comment {
                    file: "f".into(),
                    line: 1,
                    end_line: None,
                    text: "t".into(),
                }],
            },
            &config,
        ),
        WorkflowState::HumanReview.next(Event::CreatePr, &config),
        WorkflowState::PrCreated.next(Event::AddressGithubReviews { pr_number: 1 }, &config),
    ];

    for t in &transitions {
        for effect in &t.effects {
            match effect {
                SideEffect::SendToCodingAgent { prompt }
                | SideEffect::SendToReviewAgent { prompt } => {
                    assert!(
                        !prompt.contains("curl"),
                        "Found 'curl' in prompt: {}",
                        prompt
                    );
                    assert!(
                        !prompt.contains("localhost"),
                        "Found 'localhost' in prompt: {}",
                        prompt
                    );
                    assert!(
                        prompt.contains("emaclaude-signal"),
                        "Missing 'emaclaude-signal' in prompt: {}",
                        prompt
                    );
                }
                _ => {}
            }
        }
    }
}
