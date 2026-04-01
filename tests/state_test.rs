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
            assert!(prompt.contains(&format!("localhost:{}", config.port)));
            assert!(prompt.contains("/review-done"));
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
            assert!(prompt.contains(&format!("localhost:{}", config.port)));
            assert!(prompt.contains("/coding-done"));
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
            assert!(prompt.contains(&format!("localhost:{}", config.port)));
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
            assert!(prompt.contains("/coding-done"));
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
            text: "rename this variable".into(),
        },
        Comment {
            file: "src/lib.rs".into(),
            line: 10,
            text: "add docs".into(),
        },
    ];
    let t = WorkflowState::HumanReview.next(Event::HumanComments { comments }, &config);
    assert_eq!(t.state, WorkflowState::HumanReview);
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToCodingAgent { prompt } => {
            assert!(prompt.contains("src/main.rs:42: rename this variable"));
            assert!(prompt.contains("src/lib.rs:10: add docs"));
            assert!(prompt.contains(&format!("localhost:{}", config.port)));
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
            assert!(prompt.contains(&format!("localhost:{}", config.port)));
        }
        other => panic!("Expected SendToCodingAgent, got {:?}", other),
    }
}

#[test]
fn pr_created_addresses_github_reviews() {
    let config = default_config();
    let t = WorkflowState::PrCreated.next(
        Event::AddressGithubReviews { pr_number: 42 },
        &config,
    );
    assert_eq!(t.state, WorkflowState::PrCreated);
    assert_eq!(t.effects.len(), 1);
    match &t.effects[0] {
        SideEffect::SendToCodingAgent { prompt } => {
            assert!(prompt.contains("42"));
            assert!(prompt.contains("gh api"));
            assert!(prompt.contains(&format!("localhost:{}", config.port)));
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
        assert_eq!(t.state, WorkflowState::Idle, "ClearSession from {:?}", state);
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
fn unhandled_transition_returns_same_state() {
    let config = default_config();
    // Idle + CodingDone should be unhandled
    let t = WorkflowState::Idle.next(
        Event::CodingDone {
            branch: "x".into(),
        },
        &config,
    );
    assert_eq!(t.state, WorkflowState::Idle);
    assert!(t.effects.is_empty());
}
