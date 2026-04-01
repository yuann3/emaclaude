use serde_json::Value;

async fn spawn_server() -> u16 {
    let config = emaclaude::config::Config {
        port: 0,
        ..Default::default()
    };
    let (addr, server) = emaclaude::server::create(config).await.unwrap();
    tokio::spawn(server);
    addr.port()
}

#[tokio::test]
async fn health_returns_current_state() {
    let port = spawn_server().await;
    let resp = reqwest::get(format!("http://127.0.0.1:{}/health", port))
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["state"], "Idle");
}

#[tokio::test]
async fn full_workflow_via_http() {
    let port = spawn_server().await;
    let client = reqwest::Client::new();
    let base = format!("http://127.0.0.1:{}", port);

    // planning-done -> Coding
    let resp = client
        .post(format!("{}/planning-done", base))
        .json(&serde_json::json!({ "prompt": "build feature", "spec_path": "/tmp/spec.md" }))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "ok");
    assert_eq!(body["state"], "Coding");

    // coding-done -> Reviewing
    let resp = client
        .post(format!("{}/coding-done", base))
        .json(&serde_json::json!({ "branch": "feat-x" }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["state"], "Reviewing");

    // review-done (approved) -> Confirming { approval_count: 1 }
    let resp = client
        .post(format!("{}/review-done", base))
        .json(&serde_json::json!({ "status": "approved", "feedback": "" }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert!(body["state"].as_str().unwrap().contains("Confirming"));

    // review-done (approved again) -> Confirming { approval_count: 2 }
    let resp = client
        .post(format!("{}/review-done", base))
        .json(&serde_json::json!({ "status": "approved", "feedback": "" }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert!(body["state"].as_str().unwrap().contains("Confirming"));

    // Third confirmation approval -> Confirming { approval_count: 3 }
    let resp = client
        .post(format!("{}/review-done", base))
        .json(&serde_json::json!({ "status": "approved", "feedback": "" }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert!(body["state"].as_str().unwrap().contains("Confirming"));

    // Fourth approval -> approval_count (3) >= confirmation_loops (3) -> HumanReview
    let resp = client
        .post(format!("{}/review-done", base))
        .json(&serde_json::json!({ "status": "approved", "feedback": "" }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["state"], "HumanReview");

    // Verify via health endpoint
    let resp = reqwest::get(format!("{}/health", base)).await.unwrap();
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["state"], "HumanReview");
}

#[tokio::test]
async fn review_loop_with_changes() {
    let port = spawn_server().await;
    let client = reqwest::Client::new();
    let base = format!("http://127.0.0.1:{}", port);

    // planning-done -> Coding
    client
        .post(format!("{}/planning-done", base))
        .json(&serde_json::json!({ "prompt": "build feature", "spec_path": "/tmp/spec.md" }))
        .send()
        .await
        .unwrap();

    // coding-done -> Reviewing
    client
        .post(format!("{}/coding-done", base))
        .json(&serde_json::json!({ "branch": "feat-x" }))
        .send()
        .await
        .unwrap();

    // review-done (changes_needed) -> Coding
    let resp = client
        .post(format!("{}/review-done", base))
        .json(&serde_json::json!({ "status": "changes_needed", "feedback": "fix tests" }))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["status"], "ok");
    assert_eq!(body["state"], "Coding");
}
