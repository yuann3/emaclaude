use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkflowState {
    Idle,
    Coding,
    Reviewing,
    Confirming { approval_count: u32 },
    HumanReview,
    PrCreated,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReviewStatus {
    Approved,
    ChangesNeeded,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Comment {
    pub file: String,
    pub line: u32,
    pub end_line: Option<u32>,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Event {
    PlanningDone {
        prompt: String,
        spec_path: String,
    },
    CodingDone {
        branch: String,
    },
    ReviewDone {
        status: ReviewStatus,
        feedback: String,
    },
    HumanComments {
        comments: Vec<Comment>,
    },
    CreatePr,
    AddressGithubReviews {
        pr_number: u64,
    },
    ClearSession,
    CycleComplete,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SideEffect {
    SpawnCodingAgent { prompt: String, spec_path: String },
    SpawnReviewAgent,
    SendToCodingAgent { prompt: String },
    SendToReviewAgent { prompt: String },
    OpenDiffView,
    RefreshDiffView,
    Notify { message: String },
    Shutdown,
    ResetCodingAndReview,
    InsertIntoPlanningBuffer { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Transition {
    pub state: WorkflowState,
    pub effects: Vec<SideEffect>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowConfig {
    pub confirmation_loops: u32,
}

const CODING_DONE_SIGNAL: &str =
    "When done, report via: emaclaude-signal coding-done '{{\"branch\": \"current\"}}'";
const REVIEW_DONE_SIGNAL: &str = "When done, report via: emaclaude-signal review-done '{{\"status\": \"approved\"}}' or '{{\"status\": \"changes_needed\", \"feedback\": \"...\"}}'";

fn request_review_prompt(branch: &str) -> String {
    format!(
        "Review the git diff of branch '{}' against main. Check for:\n\
         0. Skill usage — discover and apply any relevant local skills for code review (from AGENTS/SKILL instructions), then proceed with this review\n\
         1. Code quality — clean, idiomatic, well-structured\n\
         2. Security — no vulnerabilities, injection risks, or leaked secrets\n\
         3. Redundant code — no duplication, dead code, or unnecessary complexity\n\
         4. Spec adherence — does the implementation match the spec?\n\n\
         {}",
        branch, REVIEW_DONE_SIGNAL
    )
}

fn request_confirmation_review_prompt(round: Option<u32>) -> String {
    match round {
        Some(round) => format!(
            "Re-review the changes for confirmation (round {}). {}",
            round, REVIEW_DONE_SIGNAL
        ),
        None => format!(
            "Re-review the changes for confirmation. {}",
            REVIEW_DONE_SIGNAL
        ),
    }
}

fn request_coding_follow_up_prompt(prefix: &str, feedback: &str) -> String {
    format!("{}\n{}\n\n{}", prefix, feedback, CODING_DONE_SIGNAL)
}

fn request_create_pr_prompt() -> String {
    format!(
        "Create a pull request for the current branch. Use gh CLI to create the PR.\n\n{}",
        CODING_DONE_SIGNAL
    )
}

fn request_github_review_prompt(pr_number: u64) -> String {
    format!(
        "Fetch review comments from PR #{} using `gh api`. \
         For each comment: fix the issue, reply to the comment on GitHub, \
         and resolve the conversation. Push all fixes. \
         Do NOT re-request review.\n\n{}",
        pr_number, CODING_DONE_SIGNAL
    )
}

fn format_comment(comment: &Comment) -> String {
    match comment.end_line {
        Some(end_line) if end_line > comment.line => format!(
            "  - {}:{}-{}: {}",
            comment.file, comment.line, end_line, comment.text
        ),
        _ => format!("  - {}:{}: {}", comment.file, comment.line, comment.text),
    }
}

impl Default for WorkflowConfig {
    fn default() -> Self {
        Self {
            confirmation_loops: 2,
        }
    }
}

impl WorkflowState {
    pub fn next(self, event: Event, config: &WorkflowConfig) -> Transition {
        // ClearSession from any state
        if let Event::ClearSession = &event {
            return Transition {
                state: WorkflowState::Idle,
                effects: vec![
                    SideEffect::Notify {
                        message: "Session cleared".to_string(),
                    },
                    SideEffect::Shutdown,
                ],
            };
        }

        // CycleComplete from any non-Idle state
        if let Event::CycleComplete = &event {
            if self == WorkflowState::Idle {
                return Transition {
                    state: WorkflowState::Idle,
                    effects: vec![],
                };
            }
            return Transition {
                state: WorkflowState::Idle,
                effects: vec![
                    SideEffect::ResetCodingAndReview,
                    SideEffect::InsertIntoPlanningBuffer {
                        message: "Implementation is done. Let's move on to the next task."
                            .to_string(),
                    },
                    SideEffect::Notify {
                        message: "Cycle complete. Ready for next planning session.".to_string(),
                    },
                ],
            };
        }

        match (self.clone(), event) {
            // 1. Idle + PlanningDone → Coding
            (WorkflowState::Idle, Event::PlanningDone { prompt, spec_path }) => Transition {
                state: WorkflowState::Coding,
                effects: vec![
                    SideEffect::SpawnCodingAgent { prompt, spec_path },
                    SideEffect::SpawnReviewAgent,
                ],
            },

            // 2. Coding + CodingDone → Reviewing
            (WorkflowState::Coding, Event::CodingDone { branch }) => Transition {
                state: WorkflowState::Reviewing,
                effects: vec![SideEffect::SendToReviewAgent {
                    prompt: request_review_prompt(&branch),
                }],
            },

            // 3. Reviewing + ReviewDone(ChangesNeeded) → Coding
            (
                WorkflowState::Reviewing,
                Event::ReviewDone {
                    status: ReviewStatus::ChangesNeeded,
                    feedback,
                },
            ) => Transition {
                state: WorkflowState::Coding,
                effects: vec![SideEffect::SendToCodingAgent {
                    prompt: request_coding_follow_up_prompt(
                        "Address the following review feedback:",
                        &feedback,
                    ),
                }],
            },

            // 4. Reviewing + ReviewDone(Approved) → Confirming(1)
            (
                WorkflowState::Reviewing,
                Event::ReviewDone {
                    status: ReviewStatus::Approved,
                    ..
                },
            ) => Transition {
                state: WorkflowState::Confirming { approval_count: 1 },
                effects: vec![SideEffect::SendToReviewAgent {
                    prompt: request_confirmation_review_prompt(None),
                }],
            },

            // 5/6/7. Confirming + ReviewDone
            (
                WorkflowState::Confirming { approval_count },
                Event::ReviewDone { status, feedback },
            ) => match status {
                ReviewStatus::Approved if approval_count >= config.confirmation_loops => {
                    Transition {
                        state: WorkflowState::HumanReview,
                        effects: vec![
                            SideEffect::OpenDiffView,
                            SideEffect::Notify {
                                message: "Code review complete. Ready for human review."
                                    .to_string(),
                            },
                        ],
                    }
                }
                ReviewStatus::Approved => Transition {
                    state: WorkflowState::Confirming {
                        approval_count: approval_count + 1,
                    },
                    effects: vec![SideEffect::SendToReviewAgent {
                        prompt: request_confirmation_review_prompt(Some(approval_count + 1)),
                    }],
                },
                ReviewStatus::ChangesNeeded => Transition {
                    state: WorkflowState::Coding,
                    effects: vec![SideEffect::SendToCodingAgent {
                        prompt: request_coding_follow_up_prompt(
                            "Address the following review feedback:",
                            &feedback,
                        ),
                    }],
                },
            },

            // 8. HumanReview + HumanComments → HumanReview
            (WorkflowState::HumanReview, Event::HumanComments { comments }) => {
                let formatted = comments
                    .iter()
                    .map(format_comment)
                    .collect::<Vec<_>>()
                    .join("\n");
                Transition {
                    state: WorkflowState::HumanReview,
                    effects: vec![SideEffect::SendToCodingAgent {
                        prompt: request_coding_follow_up_prompt(
                            "Address the following human review comments:",
                            &formatted,
                        ),
                    }],
                }
            }

            // 9. HumanReview + CreatePr → PrCreated
            (WorkflowState::HumanReview, Event::CreatePr) => Transition {
                state: WorkflowState::PrCreated,
                effects: vec![SideEffect::SendToCodingAgent {
                    prompt: request_create_pr_prompt(),
                }],
            },

            // 10. PrCreated + AddressGithubReviews → PrCreated
            (WorkflowState::PrCreated, Event::AddressGithubReviews { pr_number }) => Transition {
                state: WorkflowState::PrCreated,
                effects: vec![SideEffect::SendToCodingAgent {
                    prompt: request_github_review_prompt(pr_number),
                }],
            },

            // HumanReview + CodingDone → stay in HumanReview, refresh diff
            (WorkflowState::HumanReview, Event::CodingDone { .. }) => Transition {
                state: WorkflowState::HumanReview,
                effects: vec![
                    SideEffect::RefreshDiffView,
                    SideEffect::Notify {
                        message: "Coding agent finished fixes. Diff refreshed.".to_string(),
                    },
                ],
            },

            // PrCreated + CodingDone → stay in PrCreated, refresh diff
            (WorkflowState::PrCreated, Event::CodingDone { .. }) => Transition {
                state: WorkflowState::PrCreated,
                effects: vec![
                    SideEffect::RefreshDiffView,
                    SideEffect::Notify {
                        message: "GitHub review fixes complete. Diff refreshed.".to_string(),
                    },
                ],
            },

            // Unhandled → same state, no effects
            (state, _) => Transition {
                state,
                effects: vec![],
            },
        }
    }
}
