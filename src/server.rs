use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;

use axum::{
    Json, Router,
    extract::State,
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use crate::config::Config;
use crate::effects::EffectExecutor;
use crate::emacs::EmacsBridge;
use crate::state::{Comment, Event, ReviewStatus, WorkflowConfig, WorkflowState};

pub struct AppState {
    pub workflow: WorkflowState,
    pub workflow_config: WorkflowConfig,
    pub config: Config,
    pub executor: Arc<EffectExecutor>,
}

#[derive(Serialize)]
struct HealthResponse {
    state: String,
}

#[derive(Serialize)]
struct OkResponse {
    status: String,
    state: String,
}

#[derive(Deserialize)]
struct PlanningDoneRequest {
    prompt: String,
    spec_path: String,
}

#[derive(Deserialize)]
struct CodingDoneRequest {
    branch: String,
}

#[derive(Deserialize)]
struct ReviewDoneRequest {
    status: String,
    #[serde(default)]
    feedback: String,
}

#[derive(Deserialize)]
struct HumanReviewRequest {
    comments: Vec<CommentRequest>,
}

#[derive(Deserialize)]
struct CommentRequest {
    file: String,
    line: u32,
    text: String,
}

type SharedState = Arc<Mutex<AppState>>;

async fn health(State(state): State<SharedState>) -> Json<HealthResponse> {
    let app = state.lock().await;
    Json(HealthResponse {
        state: format!("{:?}", app.workflow),
    })
}

async fn planning_done(
    State(state): State<SharedState>,
    Json(body): Json<PlanningDoneRequest>,
) -> Json<OkResponse> {
    let (effects, executor, new_state) = {
        let mut app = state.lock().await;
        let event = Event::PlanningDone {
            prompt: body.prompt,
            spec_path: body.spec_path,
        };
        let transition = app.workflow.clone().next(event, &app.workflow_config);
        for effect in &transition.effects {
            tracing::info!(?effect, "side effect");
        }
        app.workflow = transition.state;
        let state_str = format!("{:?}", app.workflow);
        (transition.effects, Arc::clone(&app.executor), state_str)
    };
    if let Err(e) = executor.execute(effects).await {
        tracing::error!("effect execution error: {e:#}");
    }
    Json(OkResponse {
        status: "ok".to_string(),
        state: new_state,
    })
}

async fn coding_done(
    State(state): State<SharedState>,
    Json(body): Json<CodingDoneRequest>,
) -> Json<OkResponse> {
    let (effects, executor, new_state) = {
        let mut app = state.lock().await;
        let event = Event::CodingDone {
            branch: body.branch,
        };
        let transition = app.workflow.clone().next(event, &app.workflow_config);
        for effect in &transition.effects {
            tracing::info!(?effect, "side effect");
        }
        app.workflow = transition.state;
        let state_str = format!("{:?}", app.workflow);
        (transition.effects, Arc::clone(&app.executor), state_str)
    };
    if let Err(e) = executor.execute(effects).await {
        tracing::error!("effect execution error: {e:#}");
    }
    Json(OkResponse {
        status: "ok".to_string(),
        state: new_state,
    })
}

async fn review_done(
    State(state): State<SharedState>,
    Json(body): Json<ReviewDoneRequest>,
) -> Json<OkResponse> {
    let (effects, executor, new_state) = {
        let mut app = state.lock().await;
        let status = match body.status.as_str() {
            "approved" => ReviewStatus::Approved,
            _ => ReviewStatus::ChangesNeeded,
        };
        let event = Event::ReviewDone {
            status,
            feedback: body.feedback,
        };
        let transition = app.workflow.clone().next(event, &app.workflow_config);
        for effect in &transition.effects {
            tracing::info!(?effect, "side effect");
        }
        app.workflow = transition.state;
        let state_str = format!("{:?}", app.workflow);
        (transition.effects, Arc::clone(&app.executor), state_str)
    };
    if let Err(e) = executor.execute(effects).await {
        tracing::error!("effect execution error: {e:#}");
    }
    Json(OkResponse {
        status: "ok".to_string(),
        state: new_state,
    })
}

async fn human_review(
    State(state): State<SharedState>,
    Json(body): Json<HumanReviewRequest>,
) -> Json<OkResponse> {
    let (effects, executor, new_state) = {
        let mut app = state.lock().await;
        let comments = body
            .comments
            .into_iter()
            .map(|c| Comment {
                file: c.file,
                line: c.line,
                text: c.text,
            })
            .collect();
        let event = Event::HumanComments { comments };
        let transition = app.workflow.clone().next(event, &app.workflow_config);
        for effect in &transition.effects {
            tracing::info!(?effect, "side effect");
        }
        app.workflow = transition.state;
        let state_str = format!("{:?}", app.workflow);
        (transition.effects, Arc::clone(&app.executor), state_str)
    };
    if let Err(e) = executor.execute(effects).await {
        tracing::error!("effect execution error: {e:#}");
    }
    Json(OkResponse {
        status: "ok".to_string(),
        state: new_state,
    })
}

async fn create_pr(State(state): State<SharedState>) -> Json<OkResponse> {
    let (effects, executor, new_state) = {
        let mut app = state.lock().await;
        let event = Event::CreatePr;
        let transition = app.workflow.clone().next(event, &app.workflow_config);
        for effect in &transition.effects {
            tracing::info!(?effect, "side effect");
        }
        app.workflow = transition.state;
        let state_str = format!("{:?}", app.workflow);
        (transition.effects, Arc::clone(&app.executor), state_str)
    };
    if let Err(e) = executor.execute(effects).await {
        tracing::error!("effect execution error: {e:#}");
    }
    Json(OkResponse {
        status: "ok".to_string(),
        state: new_state,
    })
}

pub async fn create(config: Config) -> anyhow::Result<(SocketAddr, impl Future<Output = ()>)> {
    let workflow_config = WorkflowConfig {
        confirmation_loops: config.confirmation_loops,
        port: config.port,
    };

    let bridge = EmacsBridge::new(config.emacsclient_path.clone());
    let executor = Arc::new(EffectExecutor::new(bridge, config.clone()));

    let shared_state: SharedState = Arc::new(Mutex::new(AppState {
        workflow: WorkflowState::Idle,
        workflow_config,
        config: config.clone(),
        executor,
    }));

    let app = Router::new()
        .route("/health", get(health))
        .route("/planning-done", post(planning_done))
        .route("/coding-done", post(coding_done))
        .route("/review-done", post(review_done))
        .route("/human-review", post(human_review))
        .route("/create-pr", post(create_pr))
        .with_state(shared_state);

    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{}", config.port)).await?;
    let addr = listener.local_addr()?;

    let server = async move {
        axum::serve(listener, app).await.unwrap();
    };

    Ok((addr, server))
}

pub async fn run(config: Config) -> anyhow::Result<()> {
    let (_addr, server) = create(config).await?;
    server.await;
    Ok(())
}
