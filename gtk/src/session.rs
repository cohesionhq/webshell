//! One loaded web UI: a web view showing it, served from its assets by a
//! URI scheme, and talking to the daemon through a `SocketBridge`.

use std::{rc::Rc, sync::Arc};

use gtk::{gio, prelude::*};
use webkit6::{
    NavigationPolicyDecision, NetworkSession, PolicyDecisionType, UserContentInjectedFrames,
    UserContentManager, UserScript, UserScriptInjectionTime, WebContext, WebView, prelude::*,
};

use crate::{assets::WebAssets, bridge::SocketBridge, pairing::RemotePairing, serving};

pub struct WebUISession {
    pub pairing: RemotePairing,
    pub view: WebView,
    _bridge: Rc<SocketBridge>,
}

impl WebUISession {
    /// A web view for `assets`, opened at `cohesion://app/#token=<token>`
    /// with a fresh token: the page reads it from the URL it is first
    /// opened at. Each session has its own web context, so the scheme
    /// answers for this page alone; `network` is the account's, shared by
    /// its pages, and with it their storage.
    pub fn new(
        pairing: RemotePairing,
        assets: Arc<WebAssets>,
        network: &NetworkSession,
        on_update: impl Fn() + 'static,
    ) -> WebUISession {
        let token = fresh_token();
        let context = WebContext::new();
        serving::register(&context, assets.clone(), token.clone(), pairing.base_url());

        let content = UserContentManager::new();
        content.add_script(&UserScript::new(
            crate::bridge::SCRIPT,
            UserContentInjectedFrames::TopFrame,
            UserScriptInjectionTime::Start,
            &[],
            &[],
        ));
        let view = WebView::builder()
            .web_context(&context)
            .network_session(network)
            .user_content_manager(&content)
            .build();
        let bridge = SocketBridge::attach(
            &content,
            &view,
            pairing.clone(),
            token.clone(),
            assets.hash.clone(),
            on_update,
        );
        if let Some(settings) = WebViewExt::settings(&view) {
            settings.set_enable_developer_extras(cfg!(debug_assertions));
            // The UI routes within one page; a swipe back would leave it
            // for whatever the history holds.
            settings.set_enable_back_forward_navigation_gestures(false);
        }
        view.connect_decide_policy(keep_own_origin);
        view.load_uri(&format!("{}#token={token}", serving::ORIGIN));
        WebUISession {
            pairing,
            view,
            _bridge: bridge,
        }
    }
}

/// Keeps the page on the UI's own origin and opens anything else, like an
/// account's sign-in page or an article, in the default browser.
fn keep_own_origin(
    view: &WebView,
    decision: &webkit6::PolicyDecision,
    kind: PolicyDecisionType,
) -> bool {
    if !matches!(
        kind,
        PolicyDecisionType::NavigationAction | PolicyDecisionType::NewWindowAction
    ) {
        return false;
    }
    let Some(uri) = decision
        .downcast_ref::<NavigationPolicyDecision>()
        .and_then(|decision| decision.navigation_action())
        .and_then(|action| action.request())
        .and_then(|request| request.uri())
    else {
        return false;
    };
    let scheme = uri.split(':').next().unwrap_or_default();
    if kind == PolicyDecisionType::NavigationAction
        && matches!(scheme, serving::SCHEME | "about" | "blob")
    {
        return false;
    }
    decision.ignore();
    let window = view.root().and_downcast::<gtk::Window>();
    gtk::UriLauncher::new(&uri).launch(window.as_ref(), None::<&gio::Cancellable>, |_| {});
    true
}

/// 32 random letters and digits, like `cohesion open`'s launch token.
fn fresh_token() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let mut bytes = [0u8; 32];
    rustls::crypto::aws_lc_rs::default_provider()
        .secure_random
        .fill(&mut bytes)
        .expect("the system random source is available");
    bytes
        .iter()
        .map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char)
        .collect()
}
