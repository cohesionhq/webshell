//! Serves the web UI at the root of `cohesion://app/`, as `cohesion open`
//! serves it on loopback, with no port open: each file at `/<path>` with a
//! matching `Content-Type`, `index.html` for any other path, and
//! `GET /client` for a page that presents the session's token.

use std::sync::Arc;

use gtk::{gio, glib};
use serde::Serialize;
use webkit6::{
    URISchemeRequest, URISchemeResponse, WebContext,
    soup::{MessageHeaders, MessageHeadersType},
};

use crate::assets::WebAssets;

pub const SCHEME: &str = "cohesion";
pub const ORIGIN: &str = "cohesion://app/";

/// What `/client` tells the UI about the client it runs behind. The app
/// keeps no workspace of its own, so the UI picks one as it does in a browser.
#[derive(Serialize)]
struct ClientInfo<'a> {
    workspace: Option<i64>,
    target: &'a str,
}

/// Registers the scheme on `context`, answering from `assets` for a page
/// holding `token`. `target` is where the daemon is, as `/client` says.
pub fn register(context: &WebContext, assets: Arc<WebAssets>, token: String, target: String) {
    let security = context
        .security_manager()
        .expect("a web context has a security manager");
    // A secure context, as loopback is in a browser: the page uses
    // `crypto.randomUUID` and the like.
    security.register_uri_scheme_as_secure(SCHEME);
    security.register_uri_scheme_as_cors_enabled(SCHEME);
    context.register_uri_scheme(SCHEME, move |request| {
        let (status, content_type, cache, body) = answer(request, &assets, &token, &target);
        respond(request, status, content_type, cache, body);
    });
}

fn answer(
    request: &URISchemeRequest,
    assets: &WebAssets,
    token: &str,
    target: &str,
) -> (u32, String, &'static str, glib::Bytes) {
    let path = request.path().unwrap_or_default();
    let path = path.trim_start_matches('/');
    if path == "client" {
        let authorization = request
            .http_headers()
            .and_then(|headers| headers.one("Authorization"));
        if authorization.as_deref() != Some(&format!("Bearer {token}")) {
            return text(401, "missing or wrong launch token");
        }
        let info = ClientInfo {
            workspace: None,
            target,
        };
        let body = serde_json::to_vec(&info).expect("client info always serializes");
        return (
            200,
            "application/json".into(),
            "no-store",
            glib::Bytes::from_owned(body),
        );
    }
    let Some((path, data)) = assets.file(path) else {
        return text(404, "the web UI has no index.html");
    };
    let (content_type, _) = gio::content_type_guess(Some(path), None);
    let content_type = gio::content_type_get_mime_type(&content_type)
        .map(|mime| mime.to_string())
        .unwrap_or_else(|| "application/octet-stream".into());
    // SvelteKit content-hashes everything under `_app/immutable/`.
    let cache = if path.starts_with("_app/immutable/") {
        "public, max-age=31536000, immutable"
    } else {
        "no-cache"
    };
    (200, content_type, cache, data.clone())
}

fn text(status: u32, body: &'static str) -> (u32, String, &'static str, glib::Bytes) {
    (
        status,
        "text/plain".into(),
        "no-store",
        glib::Bytes::from_static(body.as_bytes()),
    )
}

fn respond(
    request: &URISchemeRequest,
    status: u32,
    content_type: String,
    cache: &str,
    body: glib::Bytes,
) {
    let length = body.len() as i64;
    let stream = gio::MemoryInputStream::from_bytes(&body);
    let response = URISchemeResponse::new(&stream, length);
    response.set_status(status, None);
    response.set_content_type(&content_type);
    let headers = MessageHeaders::new(MessageHeadersType::Response);
    headers.append("Cache-Control", cache);
    response.set_http_headers(headers);
    request.finish_with_response(&response);
}
