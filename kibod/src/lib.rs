pub mod ai;
pub mod api;
pub mod knowledge;
pub mod model;
pub mod state;
pub mod store;
pub mod ui;
mod workflow;

use ai::Ai;
use axum::Router;
use axum::extract::Request;
use axum::http::{StatusCode, header};
use axum::middleware::{Next, from_fn};
use axum::response::{IntoResponse, Response};
use state::AppState;
use store::Store;
use tower_http::trace::TraceLayer;

pub fn app(store: Store, ai: Ai) -> anyhow::Result<Router> {
    let state = AppState::new(store, ai);
    state.resume()?;
    Ok(Router::new()
        .merge(api::router())
        .merge(ui::router())
        .layer(from_fn(same_origin_browser_requests))
        .layer(TraceLayer::new_for_http())
        .with_state(state))
}

async fn same_origin_browser_requests(request: Request, next: Next) -> Response {
    let headers = request.headers();
    let origin = headers
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok());
    let host = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok());
    let websocket = headers
        .get(header::UPGRADE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket"));

    if let Some(origin) = origin {
        let origin_host = origin.parse::<axum::http::Uri>().ok().and_then(|uri| {
            uri.authority()
                .map(|authority| authority.as_str().to_string())
        });
        if origin_host
            .as_deref()
            .zip(host)
            .is_none_or(|(origin_host, host)| !origin_host.eq_ignore_ascii_case(host))
        {
            return (StatusCode::FORBIDDEN, "cross-origin request rejected").into_response();
        }
    } else if websocket {
        return (StatusCode::FORBIDDEN, "WebSocket Origin header required").into_response();
    }

    next.run(request).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use tower::ServiceExt;

    #[tokio::test]
    async fn cross_origin_browser_mutation_is_rejected() {
        let temporary = tempfile::tempdir().unwrap();
        let service = app(Store::open(temporary.path()).unwrap(), Ai::mock()).unwrap();
        let response = service
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/projects")
                    .header(header::HOST, "127.0.0.1:3000")
                    .header(header::ORIGIN, "https://malicious.example")
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(r#"{"name":"Injected"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }
}
